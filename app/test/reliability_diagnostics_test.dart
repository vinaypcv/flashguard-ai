import 'dart:io';

import 'package:flashguard_ai/core/integrity_engine.dart';
import 'package:flashguard_ai/core/transfer_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/storage_reliability/disk_full.dart';
import '../tool/storage_reliability/environment.dart';
import '../tool/storage_reliability/model.dart';

void main() {
  test(
      'Production probes distinguish flushed data, saved checkpoints and verification',
      () async {
    final root = await Directory.systemTemp.createTemp('fg_diagnostics_');
    try {
      final source = File('${root.path}/source.bin');
      await source.writeAsBytes(List.generate(128, (i) => i));
      final vault = await Directory('${root.path}/vault').create();
      final metrics = TransferDiagnostics();
      final stages = <TransferProbeStage>[];
      var metadataBytes = 0;
      final result = await IntegrityEngine.verifiedOffload(
          source: source,
          destinationDir: vault,
          checkpointBlockBytes: 32,
          diagnostics: metrics,
          onProbe: (probe) async {
            stages.add(probe.stage);
            if (probe.stage == TransferProbeStage.blockFlushed &&
                probe.offset == 32) {
              expect(
                  await File('${vault.path}/source.bin.checkpoint.json')
                      .exists(),
                  isFalse);
            }
            if (probe.stage == TransferProbeStage.checkpointSaved) {
              metadataBytes +=
                  await File('${vault.path}/source.bin.checkpoint.json')
                      .length();
            }
          });
      expect(result.byteForByteVerified, isTrue);
      expect(metrics.copyBytesWritten, 128);
      expect(metrics.checkpointMetadataBytesWritten, metadataBytes);
      expect(stages.take(2), [
        TransferProbeStage.blockFlushed,
        TransferProbeStage.checkpointSaved
      ]);
      expect(stages.indexOf(TransferProbeStage.verificationBlockRead),
          greaterThan(stages.indexOf(TransferProbeStage.verificationStarted)));
      expect(stages.indexOf(TransferProbeStage.promoted),
          greaterThan(stages.indexOf(TransferProbeStage.bytesVerified)));
      expect(stages.last, TransferProbeStage.finalVerified);
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('Disk exhaustion is disabled by default and writes nothing', () async {
    final root = await Directory.systemTemp.createTemp('fg_disk_policy_');
    try {
      final result = await diskFull(root, HarnessOptions([]));
      expect(result['status'], 'skipped');
      expect(result['realEnospcObserved'], isFalse);
      expect(await root.list().toList(), isEmpty);
    } finally {
      await root.delete(recursive: true);
    }
  });

  test(
      'Disposable-volume policy rejects system disks, roots, unapproved paths and oversized volumes',
      () {
    const system =
        VolumeInfo('C:\\', 'system', 'NTFS', '', 1024 * mib, 512 * mib);
    const target = VolumeInfo('Z:\\', 'disposable', 'NTFS',
        'FLASHGUARD_DISPOSABLE', 64 * mib, 32 * mib);
    const path = r'Z:\approved';
    Map<String, dynamic> marker(String path) => {
          'purpose': 'flashguard-real-enospc',
          'disposable': true,
          'approvedDirectory': path,
          'maxAllocationBytes': 128 * mib
        };
    void validate(
            {String directory = path,
            String approval = path,
            VolumeInfo volume = target,
            Map<String, dynamic>? proof}) =>
        validateDisposableVolume(
            os: 'windows',
            path: directory,
            approvedPath: approval,
            target: volume,
            system: system,
            marker: proof ?? marker(directory),
            maxAllocation: 128 * mib);
    validate();
    expect(
        () => validate(
            directory: r'C:\approved',
            approval: r'C:\approved',
            volume: system),
        throwsStateError);
    expect(
        () => validate(directory: 'Z:\\', approval: 'Z:\\'), throwsStateError);
    expect(() => validate(approval: r'Z:\unapproved'), throwsStateError);
    expect(() => validate(proof: {}), throwsStateError);
    expect(
        () => validate(
            volume: const VolumeInfo('Z:\\', 'other', 'NTFS',
                'FLASHGUARD_DISPOSABLE', 1024 * mib, 512 * mib)),
        throwsStateError);
    expect(
        () => validate(
            volume: const VolumeInfo('Z:\\', 'other', 'NTFS',
                'NORMAL_USER_DATA', 64 * mib, 32 * mib)),
        throwsStateError);
    expect(
        () => validateDisposableVolume(
            os: 'linux',
            path: '/dev/shm/approved',
            approvedPath: '/dev/shm/approved',
            target: const VolumeInfo(
                '/dev/shm', 'tmpfs', 'tmpfs', '', 64 * mib, 32 * mib),
            system: const VolumeInfo(
                '/', '/dev/root', 'ext4', '', 1024 * mib, 512 * mib),
            marker: marker('/dev/shm/approved'),
            maxAllocation: 128 * mib),
        throwsStateError);
  });

  test(
      'Benchmark options bound allocation and do not invent p95 from small samples',
      () {
    expect(() => HarnessOptions(['--sizes-mib=65536']), throwsArgumentError);
    expect(() => HarnessOptions(['--max-allocation-mib=2048']),
        throwsArgumentError);
    expect(() => HarnessOptions(['--samples=0']), throwsArgumentError);
    expect(() => HarnessOptions(['--unknown=yes']), throwsArgumentError);
    expect(summarize([2, 3, 1])['median'], 2);
    expect(summarize([2, 3, 1])['p95'], isNull);
    expect(summarize(List.generate(20, (i) => i + 1))['p95'], 19);
  });
}
