import 'dart:io';

import 'controller.dart' show assertAudit, engineConfig, fixture, runWorker;
import 'environment.dart';
import 'model.dart';

/// Reverse pair order on alternate iterations, balancing the first position
/// for each variant when the repetition count is even. Seed fixes the first.
List<String> pairOrder(int seed, int iteration) => (seed + iteration).isEven
    ? ['baseline', 'candidate']
    : ['candidate', 'baseline'];

Map<String, Object?> variantSummary(List<Map<String, dynamic>> samples) {
  final phaseNames = <String>{};
  for (final sample in samples) {
    phaseNames.addAll(
        ((sample['metrics'] as Map)['phases'] as Map).keys.cast<String>());
  }
  return {
    'count': samples.length,
    'latencyMicros':
        summarize(samples.map((s) => s['endToEndMicros'] as num).toList()),
    'throughputMiBs':
        summarize(samples.map((s) => s['endToEndMiBs'] as num).toList()),
    'phaseBreakdown': {
      for (final phase in phaseNames)
        phase: {
          'micros': summarize(samples
              .map((s) =>
                  ((((s['metrics'] as Map)['phases'] as Map)[phase]
                      as Map?)?['micros'] as num?) ??
                  0)
              .toList()),
          'percentOfEngineTotal': summarize(samples.map((s) {
            final metrics = s['metrics'] as Map;
            final micros = (((metrics['phases'] as Map)[phase]
                    as Map?)?['micros'] as num?) ??
                0;
            return (metrics['totalMicros'] as num) == 0
                ? 0
                : micros * 100 / (metrics['totalMicros'] as num);
          }).toList()),
        }
    },
    'unattributedMicros': summarize(samples
        .map((s) => (s['metrics'] as Map)['unattributedMicros'] as num)
        .toList()),
  };
}

Map<String, Object?> compareVariants(List<Map<String, dynamic>> samples) {
  final baseline = samples.where((s) => s['variant'] == 'baseline').toList();
  final candidate = samples.where((s) => s['variant'] == 'candidate').toList();
  requireCondition(baseline.length >= 10 && candidate.length == baseline.length,
      'A/B comparison requires at least ten complete matched pairs');
  final a = variantSummary(baseline);
  final b = variantSummary(candidate);
  final ratios = <num>[];
  for (var i = 0; i < baseline.length; i++) {
    final peer = candidate
        .singleWhere((s) => s['pairIndex'] == baseline[i]['pairIndex']);
    ratios.add(((peer['endToEndMicros'] as num) /
                (baseline[i]['endToEndMicros'] as num) -
            1) *
        100);
  }
  final paired = summarize(ratios);
  final pairedMedian = paired['median'] as num;
  return {
    'baseline': a,
    'candidate': b,
    'latencyChangePercent': (((b['latencyMicros'] as Map)['median'] as num) /
                ((a['latencyMicros'] as Map)['median'] as num) -
            1) *
        100,
    'throughputChangePercent':
        (((b['throughputMiBs'] as Map)['median'] as num) /
                    ((a['throughputMiBs'] as Map)['median'] as num) -
                1) *
            100,
    'pairedLatencyChangesPercent': ratios,
    'pairedLatencyChangeSummary': paired,
    'pairsFaster': ratios.where((n) => n < 0).length,
    'exploratoryObservation': pairedMedian < -5
        ? 'improvement'
        : pairedMedian > 5
            ? 'regression'
            : 'neutral-within-5-percent',
    'interpretation':
        'The 5% band is descriptive, not a confidence interval or significance test. Negative latency changes are faster.',
  };
}

Future<Map<String, Object?>> pairedBenchmark(
    Directory root, HarnessOptions options, int sizeMiB) async {
  final size = sizeMiB * mib;
  final space = await inspectVolume(root.path);
  if (space.freeBytes < size * 2 + 1024 * mib) {
    return {
      'status': 'skipped',
      'reason': 'Preserving 1 GiB free space',
      'sizeBytes': size
    };
  }
  final area = await Directory('${root.path}/ab_$sizeMiB').create();
  final source = File('${area.path}/source.bin');
  final info = await fixture(source, size, options.seed);
  final hash = info['sha256'] as String;
  final blocks = {
    'baseline': options.baselineBlockMiB * mib,
    'candidate': options.candidateBlockMiB * mib
  };
  Future<Map<String, dynamic>> sample(
      String variant, int pair, bool warmup) async {
    final vault = await Directory(
            '${area.path}/${warmup ? 'warmup' : 'pair'}_${pair}_$variant')
        .create();
    var passed = false;
    try {
      final result = await runWorker(engineConfig(source, vault, hash,
          blockBytes: blocks[variant]!, profiling: options.profiling));
      await assertAudit(result, source, vault, hash);
      requireCondition(
          result['transferredBytes'] == size && result['resumedBytes'] == 0,
          'A/B sample did not use a fresh destination');
      if (options.profiling) {
        final metrics = result['metrics'] as Map;
        requireCondition(
            metrics['checkpointCount'] == (size / blocks[variant]!).ceil() &&
                (metrics['unattributedMicros'] as num) >= 0,
            'Phase ledger or checkpoint count invalid: $metrics');
      }
      passed = true;
      return {
        ...result,
        'variant': variant,
        'pairIndex': pair,
        'warmup': warmup
      };
    } finally {
      if (passed) await vault.delete(recursive: true);
    }
  }

  final warmups = <Map<String, dynamic>>[];
  for (final variant in pairOrder(options.seed, 0)) {
    warmups.add(await sample(variant, -1, true));
  }
  final measured = <Map<String, dynamic>>[];
  for (var pair = 0; pair < options.samples; pair++) {
    final order = pairOrder(options.seed, pair);
    for (var position = 0; position < order.length; position++) {
      stdout.writeln(
          'A/B $sizeMiB MiB pair ${pair + 1}/${options.samples}: ${order[position]}');
      measured.add({
        ...await sample(order[position], pair, false),
        'positionInPair': position,
        'sequence': measured.length
      });
    }
  }
  final result = <String, Object?>{
    'sizeBytes': size,
    'fixture': info,
    'experiment': 'checkpoint-block-size',
    'blocks': blocks,
    'productionDefaultBlockBytes': 4 * mib,
    'order': 'alternating matched pairs, seed controls initial order',
    'cacheControl':
        'fresh destinations; OS caches uncontrolled; fresh JIT workers',
    'warmups': warmups,
    'samples': measured,
    'comparison': compareVariants(measured),
    'physicalWriteAmplification': null
  };
  await area.delete(recursive: true);
  return result;
}

String comparisonMarkdown(Map<String, Object?> report) {
  final buffer = StringBuffer('# Storage A/B observations\n\n');
  buffer.writeln('Platform: ${(report['environment'] as Map)['os']}. '
      'Warm-ups excluded; raw JSON is authoritative. OS caches uncontrolled.\n');
  buffer.writeln(
      '| MiB | Baseline median ms | Candidate median ms | Latency change | Throughput change | Paired median latency change | Paired observation |');
  buffer.writeln('| ---: | ---: | ---: | ---: | ---: | ---: | --- |');
  for (final record in (report['records'] as List).cast<Map>()) {
    if (record['kind'] != 'abBenchmark' || record['status'] != 'passed') {
      continue;
    }
    final c = record['comparison'] as Map;
    num median(String variant) =>
        ((c[variant] as Map)['latencyMicros'] as Map)['median'] as num;
    buffer.writeln('| ${(record['sizeBytes'] as int) ~/ mib} | '
        '${(median('baseline') / 1000).toStringAsFixed(3)} | '
        '${(median('candidate') / 1000).toStringAsFixed(3)} | '
        '${(c['latencyChangePercent'] as num).toStringAsFixed(2)}% | '
        '${(c['throughputChangePercent'] as num).toStringAsFixed(2)}% | '
        '${((c['pairedLatencyChangeSummary'] as Map)['median'] as num).toStringAsFixed(2)}% | '
        '${c['exploratoryObservation']} |');
  }
  buffer.writeln(
      '\nPercentiles use nearest rank and are omitted below 20 samples. '
      'The 5% band is descriptive, not statistical significance. '
      'Production defaults are unchanged; larger blocks increase maximum recopy work.\n');
  return buffer.toString();
}
