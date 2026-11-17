import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flashguard_ai/core/integrity_engine.dart';
import 'package:flashguard_ai/core/transfer_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/storage_reliability/ab.dart';
import '../tool/storage_reliability/model.dart';
import '../tool/storage_reliability/publication.dart';

void main() {
  test('Disabling profiling preserves checkpoint bytes and verified results',
      () async {
    final root = await Directory.systemTemp.createTemp('fg_profile_');
    try {
      final source = File('${root.path}/source.bin');
      final bytes = List.generate(128, (i) => i);
      await source.writeAsBytes(bytes);
      final snapshots = <List<String>>[];
      final profiles = [
        TransferDiagnostics(),
        TransferDiagnostics(enabled: false)
      ];
      for (var run = 0; run < profiles.length; run++) {
        final vault = await Directory('${root.path}/vault_$run').create();
        final saved = <String>[];
        final result = await IntegrityEngine.verifiedOffload(
            source: source,
            destinationDir: vault,
            checkpointBlockBytes: 32,
            diagnostics: profiles[run],
            expectedSha256: sha256.convert(bytes).toString(),
            onProgress: (_) async {
              saved.add(await File('${vault.path}/source.bin.checkpoint.json')
                  .readAsString());
            });
        snapshots.add(saved);
        expect(result.byteForByteVerified, isTrue);
        expect(await File('${vault.path}/source.bin').readAsBytes(), bytes);
      }
      expect(snapshots[0], snapshots[1]);
      final enabled = profiles[0].toJson();
      final phases = enabled['phases'] as Map;
      expect(enabled['checkpointCount'], 4);
      expect(enabled['blockBytes'], 32);
      expect((phases['dataFlush'] as Map)['operations'], 5);
      expect((phases['checkpointSerialization'] as Map)['operations'], 4);
      expect((phases['checkpointPersistence'] as Map)['operations'], 4);
      expect((phases['sourceRead'] as Map)['bytesRead'], 128);
      expect((phases['blockWrite'] as Map)['bytesWritten'], 128);
      expect((phases['sourceHash'] as Map)['bytesRead'], 128);
      expect((phases['tempVerification'] as Map)['bytesRead'], 128);
      expect((phases['sourceConsistency'] as Map)['bytesRead'], 128);
      expect((phases['finalVerification'] as Map)['bytesRead'], 256);
      expect((phases['promotion'] as Map)['operations'], 1);
      expect(enabled['totalMicros'] as int, greaterThan(0));
      expect(enabled['unattributedMicros'] as int, greaterThanOrEqualTo(0));
      final disabled = profiles[1].toJson();
      expect(disabled['enabled'], isFalse);
      expect(disabled['phases'], isEmpty);
      expect(disabled['totalMicros'], 0);
      expect(disabled['copyBytesWritten'], 0);
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('Block-size experiments reject incompatible recovery metadata safely',
      () async {
    final root = await Directory.systemTemp.createTemp('fg_block_change_');
    try {
      final source = File('${root.path}/source.bin');
      final bytes = List.generate(1536, (i) => i & 255);
      await source.writeAsBytes(bytes);
      final vault = await Directory('${root.path}/vault').create();
      await expectLater(
          IntegrityEngine.verifiedOffload(
              source: source,
              destinationDir: vault,
              checkpointBlockBytes: 64,
              onProgress: (_) => throw const FileSystemException(
                  'Interrupt after saved block')),
          throwsA(isA<FileSystemException>()));
      final metrics = TransferDiagnostics();
      final result = await IntegrityEngine.verifiedOffload(
          source: source,
          destinationDir: vault,
          checkpointBlockBytes: 256,
          diagnostics: metrics,
          expectedSha256: sha256.convert(bytes).toString());
      expect(result.resumedBytes, 0);
      expect(metrics.checkpointCount, 6);
      expect(metrics.copyBytesWritten, bytes.length);
      expect(await source.readAsBytes(), bytes);
      expect(await File('${vault.path}/source.bin').readAsBytes(), bytes);
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('A/B pairing balances order and reports improvements and regressions',
      () {
    expect(() => HarnessOptions(['--suite=ab', '--samples=9']),
        throwsArgumentError);
    expect(() => HarnessOptions(['--profiling=invalid']), throwsArgumentError);
    expect(() => HarnessOptions(['--block-mib=typo']), throwsArgumentError);
    final first = List.generate(10, (i) => pairOrder(5904128, i).first);
    expect(first.where((name) => name == 'baseline').length, 5);
    List<Map<String, dynamic>> samples(int candidate) => [
          for (var pair = 0; pair < 10; pair++)
            for (final variant in pairOrder(5904128, pair))
              {
                'variant': variant,
                'pairIndex': pair,
                'endToEndMicros': variant == 'baseline' ? 1000 : candidate,
                'endToEndMiBs':
                    1e6 / (variant == 'baseline' ? 1000 : candidate),
                'metrics': {
                  'totalMicros': 1000,
                  'unattributedMicros': 50,
                  'phases': {
                    'sourceHash': {'micros': 100}
                  }
                },
              }
        ];
    final faster = compareVariants(samples(800));
    expect(faster['latencyChangePercent'], closeTo(-20, .001));
    expect(faster['throughputChangePercent'], closeTo(25, .001));
    expect(faster['pairsFaster'], 10);
    expect(faster['exploratoryObservation'], 'improvement');
    expect(
        compareVariants(samples(1200))['exploratoryObservation'], 'regression');
    expect(compareVariants(samples(1000))['exploratoryObservation'],
        'neutral-within-5-percent');
    final markdown = comparisonMarkdown({
      'environment': {'os': 'synthetic'},
      'records': [
        {
          'kind': 'abBenchmark',
          'status': 'passed',
          'sizeBytes': mib,
          'comparison': faster
        }
      ]
    });
    expect(markdown, contains('Paired median latency change'));
    expect(markdown, contains('| 25.00% | -20.00% | improvement |'));
  });

  test('Publication redacts paths without changing raw measurement values',
      () async {
    final published = await publicationCopy({
      'workspace': '/private/run',
      'seed': 42,
      'records': [
        {'latency': 1234, 'error': '/private/run/source.bin', 'hash': 'abc'}
      ]
    }, '/private/run');
    expect(published['workspace'], '<RUN_WORKSPACE>');
    final record = (published['records'] as List).single as Map;
    expect(record['latency'], 1234);
    expect(record['error'], '<RUN_WORKSPACE>/source.bin');
    expect(record['hash'], 'abc');
    expect(published['seed'], 42);
  });
}
