import 'dart:convert';
import 'dart:io';

import 'controller.dart' show assertAudit, engineConfig, fixture, runWorker;
import 'environment.dart';
import 'model.dart';
import 'process_worker.dart';

/// Pure policy function so rejected targets can be tested without allocating.
void validateDisposableVolume(
    {required String os,
    required String path,
    required String approvedPath,
    required VolumeInfo target,
    required VolumeInfo system,
    required Map<String, dynamic> marker,
    required int maxAllocation}) {
  String normalize(String value) =>
      (os == 'windows' ? value.toLowerCase().replaceAll('\\', '/') : value)
          .replaceFirst(RegExp(r'/+$'), '');
  final directory = normalize(path);
  final mount = normalize(target.mount);
  requireCondition(directory == normalize(approvedPath),
      'The exact directory must be approved');
  requireCondition(directory != mount && directory.startsWith('$mount/'),
      'Filesystem roots and paths outside the approved volume are forbidden');
  requireCondition(
      mount != normalize(system.mount) && target.source != system.source,
      'System volumes are forbidden');
  requireCondition(
      maxAllocation >= 32 * mib &&
          maxAllocation <= 512 * mib &&
          target.totalBytes > 0 &&
          target.totalBytes <= maxAllocation - 16 * mib,
      'Volume capacity exceeds the bounded allocation budget');
  if (os == 'windows') {
    requireCondition(!directory.startsWith('c:') && !mount.startsWith('c:'),
        'Windows C: is forbidden');
    requireCondition(target.label == 'FLASHGUARD_DISPOSABLE',
        'Disposable volume label required');
  } else if (os == 'linux') {
    requireCondition(
        target.fileSystem == 'tmpfs' &&
            mount.contains('/flashguard-disposable-'),
        'Only a separately mounted, explicitly named disposable tmpfs is supported');
  } else {
    throw UnsupportedError('Real disk-full testing unavailable on $os');
  }
  requireCondition(
      marker['purpose'] == 'flashguard-real-enospc' &&
          marker['disposable'] == true &&
          marker['approvedDirectory'] == path &&
          marker['maxAllocationBytes'] is int &&
          (marker['maxAllocationBytes'] as int) >= maxAllocation,
      'Missing or mismatched explicit disposable-volume approval marker');
}

bool isDiskFullCode(Object? code) => [28, 39, 112, 122].contains(code);

Future<Map<String, Object?>> diskFull(
    Directory root, HarnessOptions options) async {
  if (!options.diskFull) {
    return {
      'status': 'skipped',
      'reason': 'Disabled: no explicit disposable-volume opt-in',
      'realEnospcObserved': false
    };
  }
  requireCondition(options.diskFullPath != null && options.approvedPath != null,
      'Both --disk-full-path and --approve-disk-full-path are required');
  final supplied = Directory(options.diskFullPath!);
  requireCondition(
      supplied.isAbsolute && Directory(options.approvedPath!).isAbsolute,
      'Disposable volume paths must be absolute');
  final path = await supplied.resolveSymbolicLinks();
  final approved =
      await Directory(options.approvedPath!).resolveSymbolicLinks();
  final target = await inspectVolume(path);
  final system = await inspectVolume(Platform.isWindows
      ? '${Platform.environment['SystemDrive'] ?? 'C:'}\\'
      : '/');
  final markerFile = File('$path/.flashguard-disposable.json');
  requireCondition(
      await FileSystemEntity.type(markerFile.path, followLinks: false) ==
          FileSystemEntityType.file,
      'Approval marker must be a regular file');
  final marker =
      jsonDecode(await markerFile.readAsString()) as Map<String, dynamic>;
  validateDisposableVolume(
      os: Platform.operatingSystem,
      path: path,
      approvedPath: approved,
      target: target,
      system: system,
      marker: marker,
      maxAllocation: options.maxAllocation);
  final area = await Directory(path).createTemp('flashguard_enospc_');
  ProcessWorker? worker;
  try {
    final source = File('${root.path}/disk_full_source.bin');
    final hash =
        (await fixture(source, 8 * mib, options.seed))['sha256'] as String;
    final vault = await Directory('${area.path}/vault').create();
    worker = await ProcessWorker.start(engineConfig(source, vault, hash,
        hold: 'checkpointSaved', blockBytes: mib));
    final gate = await worker.ready();
    final filler = File('${area.path}/filler.bin');
    final handle = await filler.open(mode: FileMode.write);
    var bytesWritten = 0;
    int? fillerError;
    try {
      final block = fixtureBlock(options.seed + 1);
      final limit = options.maxAllocation - 16 * mib;
      while (bytesWritten + block.length <= limit) {
        await handle.writeFrom(block);
        await handle.flush();
        bytesWritten += block.length;
      }
    } on FileSystemException catch (error) {
      if (!isDiskFullCode(error.osError?.errorCode)) rethrow;
      fillerError = error.osError?.errorCode;
    } finally {
      await handle.close();
    }
    if (fillerError == null) {
      return {
        'status': 'skipped',
        'reason': 'Allocation cap reached without real ENOSPC',
        'fillerBytesWritten': bytesWritten,
        'realEnospcObserved': false
      };
    }
    worker.release();
    final failure = await worker.result();
    requireCondition(
        failure['status'] == 'failed' && isDiskFullCode(failure['nativeError']),
        'Transfer did not report a real disk-full error: $failure');
    requireCondition(!await File('${vault.path}/disk_full_source.bin').exists(),
        'Disk-full transfer created a final destination');
    await filler.delete();
    final recovered =
        await runWorker(engineConfig(source, vault, hash, blockBytes: mib));
    await assertAudit(recovered, source, vault, hash);
    return {
      'realEnospcObserved': true,
      'volume': target.toJson(),
      'fillerBytesWritten': bytesWritten,
      'fillerNativeError': fillerError,
      'checkpointReady': gate,
      'failure': failure,
      'recovery': recovered,
      'sourcePreserved': true,
      'recoveryOutcome': 'verified after freeing filler'
    };
  } finally {
    await worker?.dispose();
    // Only the newly created private experiment directory is ever removed.
    requireCondition(await area.parent.resolveSymbolicLinks() == path,
        'Refusing cleanup outside the approved directory');
    if (await area.exists()) await area.delete(recursive: true);
  }
}
