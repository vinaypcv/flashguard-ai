import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flashguard_ai/core/atomic_file_promoter.dart';

import 'disk_full.dart';
import 'environment.dart';
import 'model.dart';
import 'process_worker.dart';
import 'worker.dart';

Future<void> main(List<String> args) async {
  if (args.length == 1 && args.single == '--worker') return workerMain();
  final options = HarnessOptions(args);
  final root = await Directory.systemTemp.createTemp('flashguard_reliability_');
  final records = <Map<String, Object?>>[];
  final started = DateTime.now().toUtc().toIso8601String();
  late Map<String, Object?> environment;
  Future<void> experiment(String kind, String id,
      Future<Map<String, Object?>> Function() body) async {
    stdout.writeln('Running $id');
    try {
      records.add({
        'kind': kind,
        'id': id,
        'seed': options.seed,
        'status': 'passed',
        ...await body()
      });
    } catch (error, stack) {
      records.add({
        'kind': kind,
        'id': id,
        'seed': options.seed,
        'status': 'failed',
        'failureStage': id,
        'recoveryOutcome': 'not demonstrated',
        'error': error.toString(),
        'stack': stack.toString(),
        'workspace': root.path
      });
      stderr.writeln('$id failed: $error');
    }
  }

  try {
    final volume = await inspectVolume(root.path);
    final capabilities =
        await const NativeAtomicFilePromoter().capabilities(root);
    final revision = await Process.run('git', ['rev-parse', 'HEAD']);
    final status = await Process.run('git', ['status', '--porcelain']);
    final hashes = <String, String>{};
    for (final name in [
      'app/lib/core/integrity_engine.dart',
      'app/lib/core/atomic_file_promoter.dart',
      'app/lib/core/transfer_diagnostics.dart',
      ...await Directory('app/tool/storage_reliability')
          .list()
          .where((e) => e is File && e.path.endsWith('.dart'))
          .map((e) => e.path)
          .toList()
    ]) {
      hashes[name.replaceAll('\\', '/')] = await digest(File(name));
    }
    environment = {
      'os': Platform.operatingSystem,
      'osVersion': Platform.operatingSystemVersion,
      'dart': Platform.version,
      'executable': Platform.resolvedExecutable,
      'processors': Platform.numberOfProcessors,
      'volume': volume.toJson(),
      'nativeCapabilities': {
        'atomicNoReplace': capabilities.atomicNoReplace,
        'nativeFileSync': capabilities.nativeFileSync,
        'directorySync': capabilities.directorySync,
        'description': capabilities.description
      },
      'gitHead': (revision.stdout as String).trim(),
      'gitDirty': (status.stdout as String).trim().isNotEmpty,
      'sourceSha256': hashes
    };
    requireCondition(capabilities.atomicNoReplace,
        'Native operation unsupported: ${capabilities.description}');
    if (options.suite == 'all' || options.suite == 'reliability') {
      for (final stage in [
        'blockFlushed',
        'checkpointSaved',
        'verificationBlockRead',
        'promotionStarted',
        'promoted'
      ]) {
        await experiment('processKill', stage,
            () => killRecovery(root, options.seed, stage));
      }
      for (var round = 0; round < options.rounds; round++) {
        await experiment(
            'nativeProcessRace',
            'native-race-$round',
            () =>
                nativeRace(root, options.seed + round, round, occupied: false));
      }
      await experiment('nativeProcessRace', 'occupied-destination',
          () => nativeRace(root, options.seed, -1, occupied: true));
      await experiment('workspaceProcessRace', 'workspace-kill-restart',
          () => workspaceRace(root, options.seed));
    }
    if (options.suite != 'reliability') {
      for (final size in options.suite == 'smoke' ? [1] : options.sizes) {
        await experiment(
            'benchmark',
            'benchmark-${size}MiB',
            () => benchmark(root, options, size,
                options.suite == 'smoke' ? 2 : options.samples));
      }
    }
    await experiment(
        'diskFull', 'real-disk-full', () => diskFull(root, options));
  } catch (error, stack) {
    environment = {
      'os': Platform.operatingSystem,
      'osVersion': Platform.operatingSystemVersion,
      'dart': Platform.version,
      'setupError': error.toString()
    };
    records.add({
      'kind': 'setup',
      'id': 'setup',
      'seed': options.seed,
      'status': 'failed',
      'error': error.toString(),
      'stack': stack.toString()
    });
  }
  final failed = records.where((r) => r['status'] == 'failed').length;
  final artifact = {
    'schemaVersion': schemaVersion,
    'startedUtc': started,
    'completedUtc': DateTime.now().toUtc().toIso8601String(),
    'options': options.toJson(),
    'environment': environment,
    'summary': {
      'passed': records.where((r) => r['status'] == 'passed').length,
      'failed': failed,
      'skipped': records.where((r) => r['status'] == 'skipped').length
    },
    'workspace': root.path,
    'workspaceRetained': failed > 0,
    'records': records
  };
  final output = File(options.output);
  await output.parent.create(recursive: true);
  await output.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(artifact)}\n',
      flush: true);
  stdout.writeln('Evidence: ${output.absolute.path} ${artifact['summary']}');
  if (failed == 0) await root.delete(recursive: true);
  exitCode = failed == 0 ? 0 : 1;
}

Future<String> digest(File file) async =>
    (await sha256.bind(file.openRead()).single).toString();

Future<Map<String, Object?>> fixture(File file, int bytes, int seed) async {
  await file.parent.create(recursive: true);
  final timer = Stopwatch()..start();
  final block = fixtureBlock(seed);
  final output = await file.open(mode: FileMode.write);
  try {
    var written = 0;
    while (written < bytes) {
      final count = (bytes - written).clamp(0, block.length);
      await output.writeFrom(block, 0, count);
      written += count;
    }
    await output.flush();
  } finally {
    await output.close();
  }
  return {
    'sizeBytes': bytes,
    'sha256': await digest(file),
    'fixtureGenerationMicros': timer.elapsedMicroseconds
  };
}

Map<String, Object?> engineConfig(File source, Directory vault, String hash,
        {String? hold, int blockBytes = 256 * 1024}) =>
    {
      'source': source.absolute.path,
      'destination': vault.absolute.path,
      'expectedSha256': hash,
      'holdStage': hold,
      'blockBytes': blockBytes
    };

Future<Map<String, dynamic>> runWorker(Map<String, Object?> config) async {
  final worker = await ProcessWorker.start(config);
  try {
    return await worker.result();
  } finally {
    await worker.dispose();
  }
}

Future<void> assertAudit(Map<String, dynamic> result, File source,
    Directory vault, String expected) async {
  requireCondition(
      result['status'] == 'passed' &&
          result['state'] == 'committed' &&
          result['byteForByteVerified'] == true,
      'No verified commit: $result');
  requireCondition(
      await digest(source) == expected, 'Source deleted or changed');
  requireCondition(
      await digest(File('${vault.path}/${result['destinationFileName']}')) ==
          expected,
      'Final digest does not match the claimed commit');
}

Future<Map<String, Object?>> snapshot(File source, Directory vault) async {
  final finalFile = File('${vault.path}/${source.uri.pathSegments.last}');
  final part = File('${finalFile.path}.part');
  final checkpoint = File('${finalFile.path}.checkpoint.json');
  final result = <String, Object?>{
    'partExists': await part.exists(),
    'partBytes': await part.exists() ? await part.length() : 0,
    'finalExists': await finalFile.exists(),
    'checkpointExists': await checkpoint.exists(),
    'checkpointOffset': 0
  };
  if (await checkpoint.exists()) {
    final data =
        jsonDecode(await checkpoint.readAsString()) as Map<String, dynamic>;
    final metadata = Map<String, dynamic>.from(data)..remove('metadataSha256');
    requireCondition(
        sha256.convert(utf8.encode(jsonEncode(metadata))).toString() ==
            data['metadataSha256'],
        'Checkpoint metadata checksum mismatch');
    final offset = data['offset'] as int;
    requireCondition(offset >= 0 && offset <= await source.length(),
        'Checkpoint outside source bounds');
    result['checkpointOffset'] = offset;
    result['checkpointMetadataSha256Valid'] = true;
  }
  return result;
}

Future<Map<String, Object?>> killRecovery(
    Directory root, int seed, String stage) async {
  final area = await Directory('${root.path}/kill_$stage').create();
  final source = File('${area.path}/source.bin');
  final info = await fixture(source, 2 * mib, seed);
  final hash = info['sha256'] as String;
  final vault = await Directory('${area.path}/vault').create();
  final worker =
      await ProcessWorker.start(engineConfig(source, vault, hash, hold: stage));
  Map<String, dynamic>? gate;
  try {
    gate = await worker.ready();
    final killed = await worker.kill();
    final saved = await snapshot(source, vault);
    requireCondition((stage == 'promoted') == saved['finalExists'],
        'Unexpected promotion boundary: $saved');
    if (stage == 'blockFlushed') {
      requireCondition(
          saved['checkpointExists'] == false &&
              saved['partBytes'] == 256 * 1024,
          'Before-checkpoint test did not leave an unjournaled block: $saved');
    } else {
      requireCondition(
          saved['checkpointExists'] == true, 'Expected checkpoint at $stage');
    }
    final recovered = await runWorker(engineConfig(source, vault, hash));
    await assertAudit(recovered, source, vault, hash);
    final expectedResume = stage == 'promoted' || stage == 'blockFlushed'
        ? 0
        : saved['checkpointOffset'];
    requireCondition(recovered['resumedBytes'] == expectedResume,
        'Unexpected recovery reuse: $recovered');
    return {
      'failureStage': stage,
      'forcedExitCode': killed,
      'checkpointReady': gate,
      'snapshot': saved,
      'recoveryOutcome': 'verified',
      'fixture': info,
      'recovery': recovered,
      'sourcePreserved': true,
      'workspaceLockReleasedByProcessExit': true
    };
  } catch (error) {
    throw StateError('seed=$seed stage=$stage lastEvent=$gate error=$error');
  } finally {
    await worker.dispose();
  }
}

Future<Map<String, Object?>> nativeRace(Directory root, int seed, int round,
    {required bool occupied}) async {
  final area = await Directory('${root.path}/race_$round').create();
  final a = File('${area.path}/a.part');
  final b = File('${area.path}/b.part');
  final hashA = (await fixture(a, 64 * 1024, seed))['sha256'] as String;
  final hashB = (await fixture(b, 64 * 1024, seed + 1))['sha256'] as String;
  final target = File('${area.path}/winner.bin');
  if (occupied) await target.writeAsString('preserve existing destination');
  final priorHash = occupied ? await digest(target) : null;
  final workers = <ProcessWorker>[];
  try {
    for (final part in [a, b]) {
      workers.add(await ProcessWorker.start({
        'operation': 'native',
        'source': part.path,
        'destination': area.path,
        'holdStage': 'nativePromotion'
      }));
    }
    final gates = await Future.wait(workers.map((worker) => worker.ready()));
    requireCondition(gates[0]['pid'] != gates[1]['pid'],
        'Writers are not independent processes');
    for (final worker in workers) {
      worker.release();
    }
    final results = await Future.wait(workers.map((worker) => worker.result()));
    final successes = results.where((r) => r['status'] == 'passed').toList();
    requireCondition(successes.length == (occupied ? 0 : 1),
        'Incorrect native winners: $results');
    requireCondition(
        results.where((r) => r['promotionFailure'] == 'conflict').length ==
            (occupied ? 2 : 1),
        'Native conflict was not reported: $results');
    final finalHash = await digest(target);
    requireCondition(
        occupied
            ? finalHash == priorHash
            : finalHash == successes.single['sha256'],
        'Native winner contents were overwritten');
    for (final entry in [(a, hashA), (b, hashB)]) {
      if (occupied || finalHash != entry.$2) {
        requireCondition(await digest(entry.$1) == entry.$2,
            'Losing writer part was damaged');
      } else {
        requireCondition(
            !await entry.$1.exists(), 'Winning part was not moved');
      }
    }
    return {
      'round': round,
      'scenarioSeed': seed,
      'existingDestination': occupied,
      'gates': gates,
      'writers': results,
      'finalSha256': finalHash,
      'atomicNoReplaceDemonstrated': true
    };
  } finally {
    for (final worker in workers) {
      await worker.dispose();
    }
  }
}

Future<Map<String, Object?>> workspaceRace(Directory root, int seed) async {
  final area = await Directory('${root.path}/workspace_race').create();
  final a = File('${area.path}/a/source.bin');
  final b = File('${area.path}/b/source.bin');
  final hashA = (await fixture(a, mib, seed))['sha256'] as String;
  final hashB = (await fixture(b, mib, seed + 1))['sha256'] as String;
  final vault = await Directory('${area.path}/vault').create();
  final owner = await ProcessWorker.start(
      engineConfig(a, vault, hashA, hold: 'checkpointSaved'));
  try {
    final gate = await owner.ready();
    final contender = await runWorker(engineConfig(b, vault, hashB));
    requireCondition(
        contender['status'] == 'failed' &&
            contender['promotionFailure'] == 'io',
        'Workspace contender did not fail explicitly: $contender');
    final killed = await owner.kill();
    final retryB = await runWorker(engineConfig(b, vault, hashB));
    await assertAudit(retryB, b, vault, hashB);
    requireCondition(retryB['resumedBytes'] == 0,
        'Checkpoint from another source was trusted');
    final retryA = await runWorker(engineConfig(a, vault, hashA));
    await assertAudit(retryA, a, vault, hashA);
    requireCondition(retryA['destinationFileName'] == 'source (2).bin',
        'Numbered retry policy changed');
    await assertAudit(retryB, b, vault, hashB);
    return {
      'checkpointReady': gate,
      'contender': contender,
      'forcedExitCode': killed,
      'retryB': retryB,
      'retryA': retryA,
      'staleLockRecovered': true,
      'cooperativeWorkspaceProtection': true
    };
  } finally {
    await owner.dispose();
  }
}

Future<Map<String, Object?>> benchmark(
    Directory root, HarnessOptions options, int sizeMiB, int samples) async {
  final size = sizeMiB * mib;
  final space = await inspectVolume(root.path);
  if (space.freeBytes < size * 2 + 1024 * mib) {
    return {
      'status': 'skipped',
      'reason': 'Preserving at least 1 GiB free space',
      'sizeBytes': size
    };
  }
  final area = await Directory('${root.path}/bench_$sizeMiB').create();
  final source = File('${area.path}/source.bin');
  final info = await fixture(source, size, options.seed);
  final hash = info['sha256'] as String;
  Future<Map<String, dynamic>> sample(String name) async {
    final vault = await Directory('${area.path}/$name').create();
    try {
      final result = await runWorker(
          engineConfig(source, vault, hash, blockBytes: 4 * mib));
      await assertAudit(result, source, vault, hash);
      return result;
    } finally {
      await vault.delete(recursive: true);
    }
  }

  final warmup = await sample('warmup');
  final measured = <Map<String, dynamic>>[];
  for (var iteration = 0; iteration < samples; iteration++) {
    measured.add(await sample('sample_$iteration'));
  }
  final vault = await Directory('${area.path}/resume').create();
  final worker = await ProcessWorker.start(engineConfig(source, vault, hash,
      hold: 'checkpointSaved', blockBytes: 4 * mib));
  late Map<String, dynamic> resumed;
  late Map<String, dynamic> gate;
  try {
    gate = await worker.ready();
    await worker.kill();
    resumed =
        await runWorker(engineConfig(source, vault, hash, blockBytes: 4 * mib));
    await assertAudit(resumed, source, vault, hash);
    requireCondition(
        resumed['resumedBytes'] == gate['offset'] &&
            resumed['transferredBytes'] == size - (gate['offset'] as int),
        'Resume byte accounting failed');
  } finally {
    await worker.dispose();
  }
  final result = <String, Object?>{
    'sizeBytes': size,
    'fixture': info,
    'cacheControl': 'new destination; OS caches not evicted',
    'warmup': warmup,
    'samples': measured,
    'endToEndMiBs':
        summarize(measured.map((r) => r['endToEndMiBs'] as num).toList()),
    'endToEndMicros':
        summarize(measured.map((r) => r['endToEndMicros'] as num).toList()),
    'resume': resumed,
    'interruptedAtBytes': gate['offset'],
    'physicalWriteAmplification': null
  };
  await area.delete(recursive: true);
  return result;
}
