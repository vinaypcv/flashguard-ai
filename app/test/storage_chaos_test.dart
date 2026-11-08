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

  setUp(() async {
    tempDrive = await Directory.systemTemp.createTemp('flashguard_test_drive_');
    tempVault = await Directory.systemTemp.createTemp('flashguard_test_vault_');

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
  });

  test(
    'Flags truncated MP4 without moov atom as unverified',
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

      expect(corruptAudit.status, MediaIntegrityStatus.truncatedContainer);
      expect(corruptAudit.isCopyVerified, isFalse);
      expect(validAudit.status, MediaIntegrityStatus.valid);
      expect(validAudit.isCopyVerified, isTrue);
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
}
