import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flashguard_ai/core/atomic_file_promoter.dart';
import 'package:flashguard_ai/core/integrity_engine.dart';
import 'package:flashguard_ai/core/transfer_diagnostics.dart';
import 'package:flashguard_ai/core/transfer_state_machine.dart';

import 'environment.dart';
import 'model.dart';

Future<void> workerMain() async {
  final commands = StreamIterator(
      stdin.transform(utf8.decoder).transform(const LineSplitter()));
  final metrics = TransferDiagnostics();
  final lifecycle = TransferStateMachine();
  final timer = Stopwatch();
  Future<void> send(Map<String, Object?> event) async {
    stdout.writeln(jsonEncode({...event, 'pid': pid}));
    await stdout.flush();
  }

  try {
    if (!await commands.moveNext()) {
      throw StateError('Missing worker configuration');
    }
    final config = jsonDecode(commands.current) as Map<String, dynamic>;
    var held = false;
    Future<void> probe(String stage, int offset) async {
      if (!held && stage == config['holdStage']) {
        held = true;
        await send({
          'type': 'ready',
          'stage': stage,
          'offset': offset,
          'metrics': metrics.toJson(),
          'state': lifecycle.state.name,
          'history': lifecycle.history.map((t) => t.toString()).toList()
        });
        if (!await commands.moveNext() || commands.current != 'continue') {
          throw StateError('Controller closed the synchronization gate');
        }
      }
    }

    final beforeCpu = await processCpuMicros();
    final rssBefore = ProcessInfo.currentRss;
    final source = File(config['source'] as String);
    final destination = Directory(config['destination'] as String);
    timer.start();
    if (config['operation'] == 'native') {
      final target = File('${destination.path}/winner.bin');
      final digest = (await sha256.bind(source.openRead()).single).toString();
      await probe('nativePromotion', 0);
      await const NativeAtomicFilePromoter().promoteNoReplace(source, target);
      final finalDigest =
          (await sha256.bind(target.openRead()).single).toString();
      requireCondition(finalDigest == digest, 'Native winner digest mismatch');
      timer.stop();
      await send({
        'type': 'result',
        'status': 'passed',
        'operation': 'native',
        'sha256': digest,
        'destinationFileName': 'winner.bin',
        'endToEndMicros': timer.elapsedMicroseconds
      });
    } else {
      final result = await IntegrityEngine.verifiedOffload(
        source: source,
        destinationDir: destination,
        checkpointBlockBytes: config['blockBytes'] as int? ?? 256 * 1024,
        expectedSha256: config['expectedSha256'] as String?,
        diagnostics: metrics,
        lifecycle: lifecycle,
        onProbe: (event) => probe(event.stage.name, event.offset),
      );
      timer.stop();
      final cpuAfter = await processCpuMicros();
      await send({
        'type': 'result',
        'status': 'passed',
        'operation': 'engine',
        'state': lifecycle.state.name,
        'sha256': result.sha256Hash,
        'destinationFileName': result.destinationFileName,
        'byteSize': result.byteSize,
        'byteForByteVerified': result.byteForByteVerified,
        'resumedBytes': result.resumedBytes,
        'transferredBytes': result.transferredBytes,
        'reusedExistingCopy': result.reusedExistingCopy,
        'endToEndMicros': timer.elapsedMicroseconds,
        'endToEndMiBs':
            result.byteSize / mib / (timer.elapsedMicroseconds / 1000000),
        'copyCheckpointMiBs': metrics.copyCheckpointMicros == 0
            ? null
            : result.transferredBytes /
                mib /
                (metrics.copyCheckpointMicros / 1000000),
        'metrics': metrics.toJson(),
        'logicalWriteAmplification': result.byteSize == 0
            ? null
            : (metrics.copyBytesWritten +
                    metrics.checkpointMetadataBytesWritten) /
                result.byteSize,
        'physicalWriteAmplification': null,
        'processCpuMicros':
            beforeCpu == null || cpuAfter == null ? null : cpuAfter - beforeCpu,
        'rssBeforeBytes': rssBefore,
        'rssAfterBytes': ProcessInfo.currentRss,
        'maxRssBytes': ProcessInfo.maxRss,
        'history': lifecycle.history.map((t) => t.toString()).toList(),
      });
    }
  } catch (error, stack) {
    timer.stop();
    await send({
      'type': 'result',
      'status': 'failed',
      'error': error.toString(),
      'errorType': error.runtimeType.toString(),
      'promotionFailure': error is PromotionException ? error.kind.name : null,
      'nativeError':
          error is FileSystemException ? error.osError?.errorCode : null,
      'state': lifecycle.state.name,
      'metrics': metrics.toJson(),
      'history': lifecycle.history.map((t) => t.toString()).toList(),
      'stack': stack.toString()
    });
    exitCode = 20;
  } finally {
    await commands.cancel();
  }
}
