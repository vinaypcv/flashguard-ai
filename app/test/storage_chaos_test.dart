import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flashguard_ai/core/integrity_engine.dart';
import 'package:flashguard_ai/core/isolate_worker.dart';
import 'package:flashguard_ai/core/storage_provider.dart';
import 'package:flashguard_ai/core/telemetry_tracker.dart';
import 'package:flutter/services.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDrive;
  late Directory tempVault;
  late Directory controlDrive;

  setUp(() async {
    tempDrive = await Directory.systemTemp.createTemp('flashguard_test_drive_');
    tempVault = await Directory.systemTemp.createTemp('flashguard_test_vault_');
    controlDrive =
        await Directory.systemTemp.createTemp('flashguard_control_drive_');

    // Valid JPEG + byte-identical duplicate
    final validJpg = Uint8List.fromList([
      0xFF,
      0xD8,
      0xFF,
      0xE0,
      0x00,
      0x10,
      ...List.filled(512, 0xAB),
      0xFF,
      0xD9,
    ]);
    await File('${tempDrive.path}/IMG_001.jpg').writeAsBytes(validJpg);
    await File('${tempDrive.path}/IMG_001_dup.jpg').writeAsBytes(validJpg);
    final nearDuplicateJpg = Uint8List.fromList(validJpg);
    nearDuplicateJpg[100] = 0xAC;
    await File('${tempDrive.path}/IMG_001_near.jpg')
        .writeAsBytes(nearDuplicateJpg);

    // Valid MP4 (ftyp + moov)
    List<int> box(String type, List<int> payload) => [
          (payload.length + 8) >> 24,
          ((payload.length + 8) >> 16) & 0xff,
          ((payload.length + 8) >> 8) & 0xff,
          (payload.length + 8) & 0xff,
          ...type.codeUnits,
          ...payload,
        ];
    final ftyp = box('ftyp', [
      ...'mp42'.codeUnits,
      0,
      0,
      0,
      0,
      ...'mp42isom'.codeUnits,
    ]);
    final validMp4 = Uint8List.fromList([
      ...ftyp,
      ...box('mdat', List.filled(1024, 0x11)),
      ...box('moov', List.filled(16, 0x33)),
    ]);
    await File('${tempDrive.path}/VID_ok.mp4').writeAsBytes(validMp4);

    // Truncated MP4 (simulating USB-C disconnect before moov atom flush)
    final corruptMp4 = Uint8List.fromList([
      ...ftyp,
      ...box('mdat', [...'moov'.codeUnits, ...List.filled(512, 0x22)]),
    ]);
    await File('${tempDrive.path}/VID_disconnect_corrupt.mp4')
        .writeAsBytes(corruptMp4);
  });

  tearDown(() async {
    if (await tempDrive.exists()) await tempDrive.delete(recursive: true);
    if (await tempVault.exists()) await tempVault.delete(recursive: true);
    if (await controlDrive.exists()) await controlDrive.delete(recursive: true);
  });

  test(
    'Separates a verified byte copy from truncated media structure',
    () async {
      final summary = await IsolateOffloadWorker.runVerifiedBatch(
        sourceDirPath: tempDrive.path,
        destDirPath: tempVault.path,
      );

      final corruptAudit = summary.results.firstWhere(
        (r) => r.fileName == 'VID_disconnect_corrupt.mp4',
      );
      final validAudit = summary.results.firstWhere(
        (r) => r.fileName == 'VID_ok.mp4',
      );

      expect(corruptAudit.mediaStatus, MediaIntegrityStatus.truncatedContainer);
      expect(corruptAudit.byteForByteVerified, isTrue);
      expect(corruptAudit.byteForByteVerified, isTrue);
      expect(corruptAudit.isMediaStructurallyValid, isFalse);
      expect(
        await File('${tempVault.path}/VID_disconnect_corrupt.mp4')
            .readAsBytes(),
        await File('${tempDrive.path}/VID_disconnect_corrupt.mp4')
            .readAsBytes(),
      );
      expect(validAudit.mediaStatus, MediaIntegrityStatus.valid);
      expect(validAudit.byteForByteVerified, isTrue);
      expect(validAudit.isMediaStructurallyValid, isTrue);
    },
  );

  test('Groups exact duplicate files by SHA-256 digest', () async {
    final summary = await IsolateOffloadWorker.runVerifiedBatch(
      sourceDirPath: tempDrive.path,
      destDirPath: tempVault.path,
    );

    expect(summary.duplicateGroups.length, 1);
    final dupFiles = summary.duplicateGroups.values.first;
    expect(dupFiles, containsAll(['IMG_001.jpg', 'IMG_001_dup.jpg']));
  });

  test('Reaudits an existing verified vault without retransferring files',
      () async {
    final first = await IsolateOffloadWorker.runVerifiedBatch(
      sourceDirPath: tempDrive.path,
      destDirPath: tempVault.path,
    );
    final second = await IsolateOffloadWorker.runVerifiedBatch(
      sourceDirPath: tempDrive.path,
      destDirPath: tempVault.path,
    );

    expect(second.results.length, first.results.length);
    expect(second.results.every((result) => result.reusedExistingCopy), isTrue);
    expect(
        second.results.every((result) => result.transferredBytes == 0), isTrue);
    expect(second.results.first.resumeMessage,
        'Existing copy reverified (0 bytes transferred)');
    expect(second.duplicateGroups.length, 1);
  });

  test('Preserves a different destination and saves under a unique name',
      () async {
    final destination = File('${tempVault.path}/IMG_001.jpg');
    await destination.writeAsString('keep me');
    final source = File('${tempDrive.path}/IMG_001.jpg');
    final result = await IntegrityEngine.verifiedOffload(
      source: source,
      destinationDir: tempVault,
    );

    expect(await destination.readAsString(), 'keep me');
    expect(result.destinationFileName, 'IMG_001 (2).jpg');
    expect(
      await File('${tempVault.path}/${result.destinationFileName}')
          .readAsBytes(),
      await source.readAsBytes(),
    );
    final repeated = await IntegrityEngine.verifiedOffload(
      source: source,
      destinationDir: tempVault,
    );
    expect(repeated.destinationFileName, result.destinationFileName);
    expect(repeated.reusedExistingCopy, isTrue);
    final parts = await tempVault
        .list()
        .where((entity) => entity.path.endsWith('.part'))
        .toList();
    expect(parts, isEmpty);
  });

  test('Resumes verified blocks after a transfer interruption', () async {
    final source = File('${tempDrive.path}/IMG_001.jpg');
    await expectLater(
      IntegrityEngine.verifiedOffload(
        source: source,
        destinationDir: tempVault,
        checkpointBlockBytes: 128,
        onProgress: (_) =>
            throw const FileSystemException('Simulated disconnect'),
      ),
      throwsA(isA<FileSystemException>()),
    );

    expect(await File('${tempVault.path}/IMG_001.jpg.part').exists(), isTrue);
    expect(await File('${tempVault.path}/IMG_001.jpg.checkpoint.json').exists(),
        isTrue);
    expect(await File('${tempVault.path}/IMG_001.jpg').exists(), isFalse);

    final result = await IntegrityEngine.verifiedOffload(
      source: source,
      destinationDir: tempVault,
      checkpointBlockBytes: 128,
    );
    expect(result.resumedBytes, 128);
    expect(result.transferredBytes, result.byteSize - 128);
    expect(result.resumeMessage, contains('Resumed from'));
    expect(await File('${tempVault.path}/IMG_001.jpg').readAsBytes(),
        await source.readAsBytes());
    expect(await File('${tempVault.path}/IMG_001.jpg.checkpoint.json').exists(),
        isFalse);
  });

  test('Resumes a version 1 checkpoint and upgrades its metadata', () async {
    final source = File('${tempDrive.path}/IMG_001.jpg');
    final sourceBytes = await source.readAsBytes();
    final savedBlock = sourceBytes.take(128).toList();
    final part = File('${tempVault.path}/IMG_001.jpg.part');
    await part.writeAsBytes(savedBlock);
    await File('${tempVault.path}/IMG_001.jpg.checkpoint.json')
        .writeAsString(jsonEncode({
      'version': 1,
      'sourcePath': source.absolute.path,
      'sourceBytes': sourceBytes.length,
      'sourceSha256': sha256.convert(sourceBytes).toString(),
      'blockBytes': 128,
      'offset': 128,
      'blockSha256': [sha256.convert(savedBlock).toString()],
    }));

    final result = await IntegrityEngine.verifiedOffload(
      source: source,
      destinationDir: tempVault,
      checkpointBlockBytes: 128,
    );

    expect(result.resumedBytes, 128);
    expect(
      await File('${tempVault.path}/IMG_001.jpg').readAsBytes(),
      sourceBytes,
    );
    expect(await part.exists(), isFalse);
  });

  test('Falls back to the prior checkpoint when the newest snapshot is torn',
      () async {
    final source = File('${tempDrive.path}/IMG_001.jpg');
    await expectLater(
      IntegrityEngine.verifiedOffload(
        source: source,
        destinationDir: tempVault,
        checkpointBlockBytes: 128,
        onProgress: (progress) {
          if (progress >= 0.7) {
            throw const FileSystemException('Simulated disconnect');
          }
        },
      ),
      throwsA(isA<FileSystemException>()),
    );

    final checkpoint = File('${tempVault.path}/IMG_001.jpg.checkpoint.json');
    final backup = File('${checkpoint.path}.bak');
    expect(await backup.exists(), isTrue);
    await checkpoint.writeAsString('{torn checkpoint');

    final result = await IntegrityEngine.verifiedOffload(
      source: source,
      destinationDir: tempVault,
      checkpointBlockBytes: 128,
    );

    expect(result.resumedBytes, 256);
    expect(
      await File('${tempVault.path}/IMG_001.jpg').readAsBytes(),
      await source.readAsBytes(),
    );
    expect(await backup.exists(), isFalse);
    expect(await checkpoint.exists(), isFalse);
  });

  test('Discards a tampered checkpoint block and restarts safely', () async {
    final source = File('${tempDrive.path}/IMG_001.jpg');
    await expectLater(
      IntegrityEngine.verifiedOffload(
        source: source,
        destinationDir: tempVault,
        checkpointBlockBytes: 128,
        onProgress: (_) => throw const FileSystemException('Disconnect'),
      ),
      throwsA(isA<FileSystemException>()),
    );
    final part = File('${tempVault.path}/IMG_001.jpg.part');
    final raw = await part.readAsBytes();
    raw[40] ^= 1;
    await part.writeAsBytes(raw);
    final result = await IntegrityEngine.verifiedOffload(
      source: source,
      destinationDir: tempVault,
      checkpointBlockBytes: 128,
    );
    expect(result.resumedBytes, 0);
    expect(await File('${tempVault.path}/IMG_001.jpg').readAsBytes(),
        await source.readAsBytes());
  });

  test('Rejects same-size silent payload bit flip against trusted SHA-256',
      () async {
    final source = File('${tempDrive.path}/VID_ok.mp4');
    final expected = (await sha256.bind(source.openRead()).single).toString();
    final raw = await source.readAsBytes();
    final originalSize = raw.length;
    raw[100] ^= 1; // Inside mdat, away from all MP4 box headers.
    await source.writeAsBytes(raw);
    expect(await source.length(), originalSize);
    expect(await IntegrityEngine.inspectMediaHeader(source),
        MediaIntegrityStatus.valid);

    await expectLater(
      IntegrityEngine.verifiedOffload(
        source: source,
        destinationDir: tempVault,
        expectedSha256: expected,
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(await File('${tempVault.path}/VID_ok.mp4').exists(), isFalse);
  });

  test('Uses simulated capacity and validates native channel results',
      () async {
    final simulated =
        await const SimulatedVolumeProvider().getVolumeStats(tempDrive.path);
    expect(simulated.freeSpaceRatio, 0.68);
    expect(simulated.isHardwareBacked, isFalse);

    const channel = MethodChannel(PlatformChannelVolumeProvider.channelName);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getVolumeStats');
      return {
        'volumeLabel': 'External SSD',
        'totalBytes': 1000,
        'freeBytes': 250,
      };
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final native = await const PlatformChannelVolumeProvider()
        .getVolumeStats('content://demo');
    expect(native.freeSpaceRatio, 0.25);
    expect(native.isHardwareBacked, isTrue);
  });

  test('Detects thermal throttling after sustained throughput drop', () {
    final tracker = TelemetryTracker();
    tracker.recordSample(const Duration(seconds: 1), 500.0);
    tracker.recordSample(const Duration(seconds: 2), 500.0);
    tracker.recordSample(const Duration(seconds: 3), 500.0);
    tracker.recordSample(const Duration(seconds: 4), 500.0);
    tracker.recordSample(const Duration(seconds: 5), 200.0);
    tracker.recordSample(const Duration(seconds: 6), 200.0);
    tracker.recordSample(const Duration(seconds: 7), 200.0);
    tracker.recordSample(const Duration(seconds: 8), 200.0);

    final report = tracker.evaluate(
      totalFiles: 8,
      verifiedFiles: 8,
      freeSpaceRatio: 0.70,
    );

    expect(report.thermalThrottlingDetected, isTrue);
    expect(report.confidenceScore, lessThan(90));
  });

  test('Finds near-duplicate candidates during the batch audit', () async {
    final summary = await IsolateOffloadWorker.runVerifiedBatch(
      sourceDirPath: tempDrive.path,
      destDirPath: tempVault.path,
    );

    expect(
      summary.mediaTags
          .singleWhere((tag) => tag.fileName == 'IMG_001_near.jpg')
          .similarToFile,
      'IMG_001.jpg',
    );
    expect(
      summary.mediaTags
          .singleWhere((tag) => tag.fileName == 'IMG_001_dup.jpg')
          .similarToFile,
      isNull,
    );
  });

  test('Rejects moov text embedded inside an mdat payload', () async {
    expect(
      await IntegrityEngine.inspectMediaHeader(
        File('${tempDrive.path}/VID_disconnect_corrupt.mp4'),
      ),
      MediaIntegrityStatus.truncatedContainer,
    );
  });

  test('Recurses into nested directories and isolates a permission failure',
      () async {
    final nested = Directory('${tempDrive.path}/nested/camera');
    await nested.create(recursive: true);
    await File('${nested.path}/good.bin').writeAsBytes(List.filled(300, 0x5a));
    await File('${nested.path}/denied.bin')
        .writeAsBytes(List.filled(300, 0x6b));

    final job = await IsolateOffloadWorker.startVerifiedBatch(
      sourceDirPath: tempDrive.path,
      destDirPath: tempVault.path,
      faultInjection: const BatchFaultInjection(
        failBeforeTransfer: {'nested/camera/denied.bin'},
      ),
    );
    final summary = await job.done;

    expect(summary.totalFiles, 7);
    expect(
        summary.results.any((r) => r.relativePath == 'nested/camera/good.bin'),
        isTrue);
    expect(summary.failures.map((failure) => failure.relativePath),
        contains('nested/camera/denied.bin'));
    expect(
        File('${tempVault.path}/nested/camera/good.bin').existsSync(), isTrue);
    expect(
      File('${tempVault.path}/nested/camera/denied.bin').existsSync(),
      isFalse,
    );
  });

  test('Rejects a recursive destination inside the source tree', () async {
    final job = await IsolateOffloadWorker.startVerifiedBatch(
      sourceDirPath: tempDrive.path,
      destDirPath: '${tempDrive.path}/vault',
    );
    await expectLater(job.done, throwsA(isA<StateError>()));
    expect(await Directory('${tempDrive.path}/vault').exists(), isFalse);
  });

  test('Resumes a batch file after a deterministic interruption and bit flip',
      () async {
    final nested = Directory('${tempDrive.path}/nested');
    await nested.create();
    final source = File('${nested.path}/interrupted.bin');
    await source.writeAsBytes(List<int>.generate(1024, (i) => i & 0xff));

    final interrupted = await IsolateOffloadWorker.startVerifiedBatch(
      sourceDirPath: tempDrive.path,
      destDirPath: tempVault.path,
      checkpointBlockBytes: 128,
      faultInjection: const BatchFaultInjection(
        failAfterBytes: {'nested/interrupted.bin': 128},
      ),
    );
    final firstSummary = await interrupted.done;
    expect(firstSummary.failures.map((failure) => failure.relativePath),
        contains('nested/interrupted.bin'));

    final part = File('${tempVault.path}/nested/interrupted.bin.part');
    expect(await part.exists(), isTrue);
    final partialBytes = await part.readAsBytes();
    partialBytes[10] ^= 1;
    await part.writeAsBytes(partialBytes);

    final resumed = await IsolateOffloadWorker.startVerifiedBatch(
      sourceDirPath: tempDrive.path,
      destDirPath: tempVault.path,
      checkpointBlockBytes: 128,
    );
    final recovered = await resumed.done;
    final result = recovered.results
        .singleWhere((audit) => audit.relativePath == 'nested/interrupted.bin');
    expect(result.resumedBytes, 0);
    expect(await File('${tempVault.path}/nested/interrupted.bin').readAsBytes(),
        await source.readAsBytes());
    expect(await part.exists(), isFalse);
  });

  test('Recovers from a deterministic disk-full error and uncheckpointed tail',
      () async {
    final source = File('${controlDrive.path}/disk-full.bin');
    await source.writeAsBytes(List<int>.generate(1024, (i) => i & 0xff));

    final interrupted = await IsolateOffloadWorker.startVerifiedBatch(
      sourceDirPath: controlDrive.path,
      destDirPath: tempVault.path,
      checkpointBlockBytes: 128,
      faultInjection: const BatchFaultInjection(
        diskFullAfterBytes: {'disk-full.bin': 128},
      ),
    );
    final firstSummary = await interrupted.done;
    expect(
      firstSummary.failures.map((failure) => failure.relativePath),
      contains('disk-full.bin'),
    );

    final part = File('${tempVault.path}/disk-full.bin.part');
    expect(await part.length(), 145);
    expect(await File('${tempVault.path}/disk-full.bin').exists(), isFalse);

    final resumed = await IsolateOffloadWorker.startVerifiedBatch(
      sourceDirPath: controlDrive.path,
      destDirPath: tempVault.path,
      checkpointBlockBytes: 128,
    );
    final recovered = await resumed.done;
    final audit = recovered.results.single;
    expect(audit.resumedBytes, 128);
    expect(audit.byteForByteVerified, isTrue);
    expect(await File('${tempVault.path}/disk-full.bin').readAsBytes(),
        await source.readAsBytes());
  });

  test('Rejects an injected partial-file corruption before final promotion',
      () async {
    final source = File('${controlDrive.path}/corrupt-part.bin');
    await source.writeAsBytes(List<int>.generate(1024, (i) => i & 0xff));

    final job = await IsolateOffloadWorker.startVerifiedBatch(
      sourceDirPath: controlDrive.path,
      destDirPath: tempVault.path,
      checkpointBlockBytes: 128,
      faultInjection: const BatchFaultInjection(
        corruptPartAfterBytes: {'corrupt-part.bin': 128},
      ),
    );
    final summary = await job.done;

    expect(
      summary.failures.map((failure) => failure.relativePath),
      contains('corrupt-part.bin'),
    );
    expect(
      summary.results.any((audit) =>
          audit.relativePath == 'corrupt-part.bin' &&
          audit.byteForByteVerified),
      isFalse,
    );
    expect(await File('${tempVault.path}/corrupt-part.bin').exists(), isFalse);
    expect(await File('${tempVault.path}/corrupt-part.bin.part').exists(),
        isFalse);
  });

  test('Falls back to the prior checkpoint after injected metadata corruption',
      () async {
    final source = File('${controlDrive.path}/corrupt-checkpoint.bin');
    await source.writeAsBytes(List<int>.generate(1024, (i) => i & 0xff));

    final interrupted = await IsolateOffloadWorker.startVerifiedBatch(
      sourceDirPath: controlDrive.path,
      destDirPath: tempVault.path,
      checkpointBlockBytes: 128,
      faultInjection: const BatchFaultInjection(
        corruptCheckpointAfterBytes: {'corrupt-checkpoint.bin': 384},
      ),
    );
    final firstSummary = await interrupted.done;
    expect(
      firstSummary.failures.map((failure) => failure.relativePath),
      contains('corrupt-checkpoint.bin'),
    );
    expect(
      await File('${tempVault.path}/corrupt-checkpoint.bin.checkpoint.json.bak')
          .exists(),
      isTrue,
    );

    final resumed = await IsolateOffloadWorker.startVerifiedBatch(
      sourceDirPath: controlDrive.path,
      destDirPath: tempVault.path,
      checkpointBlockBytes: 128,
    );
    final recovered = await resumed.done;
    final audit = recovered.results.single;
    expect(audit.resumedBytes, 256);
    expect(await File('${tempVault.path}/corrupt-checkpoint.bin').readAsBytes(),
        await source.readAsBytes());
  });

  test('Restarts safely after abrupt batch-worker isolate termination',
      () async {
    final source = File('${controlDrive.path}/terminated.bin');
    await source.writeAsBytes(List<int>.generate(1024, (i) => i & 0xff));

    final terminated = await IsolateOffloadWorker.startVerifiedBatch(
      sourceDirPath: controlDrive.path,
      destDirPath: tempVault.path,
      checkpointBlockBytes: 128,
      faultInjection: const BatchFaultInjection(
        terminateAfterBytes: {'terminated.bin': 128},
      ),
    );
    await expectLater(
      terminated.done.timeout(const Duration(seconds: 5)),
      throwsA(isA<StateError>()),
    );

    expect(await File('${tempVault.path}/terminated.bin').exists(), isFalse);
    expect(await File('${tempVault.path}/terminated.bin.part').length(), 128);
    expect(
      await File('${tempVault.path}/terminated.bin.checkpoint.json').exists(),
      isTrue,
    );

    final restarted = await IsolateOffloadWorker.startVerifiedBatch(
      sourceDirPath: controlDrive.path,
      destDirPath: tempVault.path,
      checkpointBlockBytes: 128,
    );
    final recovered = await restarted.done;
    final audit = recovered.results.single;
    expect(audit.resumedBytes, 128);
    expect(audit.byteForByteVerified, isTrue);
    expect(await File('${tempVault.path}/terminated.bin').readAsBytes(),
        await source.readAsBytes());
  });

  test('Streams progress and cancels at a checkpoint that resumes safely',
      () async {
    final source = File('${controlDrive.path}/large.bin');
    await source.writeAsBytes(List<int>.generate(1024 * 1024, (i) => i & 0xff));
    final destination = Directory('${tempVault.path}/controlled');
    final job = await IsolateOffloadWorker.startVerifiedBatch(
      sourceDirPath: controlDrive.path,
      destDirPath: destination.path,
      checkpointBlockBytes: 64 * 1024,
      faultInjection: const BatchFaultInjection(chunkDelayMs: 2),
    );

    var pauseRequested = false;
    final paused = Completer<void>();
    final subscription = job.progress.listen((event) {
      if (event.state == BatchProgressState.transferring && !pauseRequested) {
        pauseRequested = true;
        job.pause();
      }
      if (event.state == BatchProgressState.paused && !paused.isCompleted) {
        paused.complete();
      }
    });
    await paused.future.timeout(const Duration(seconds: 10));
    job.cancel();
    final canceled = await job.done;
    await subscription.cancel();

    expect(canceled.cancelled, isTrue);
    expect(await File('${destination.path}/large.bin.part').exists(), isTrue);
    expect(await File('${destination.path}/large.bin').exists(), isFalse);

    final restarted = await IsolateOffloadWorker.startVerifiedBatch(
      sourceDirPath: controlDrive.path,
      destDirPath: destination.path,
      checkpointBlockBytes: 64 * 1024,
    );
    final recovered = await restarted.done;
    final result = recovered.results.single;
    expect(result.resumedBytes, greaterThan(0));
    expect(await File('${destination.path}/large.bin').readAsBytes(),
        await source.readAsBytes());
  });
}
