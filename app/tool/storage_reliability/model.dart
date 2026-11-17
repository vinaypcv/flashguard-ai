import 'dart:math';

const mib = 1024 * 1024;
const schemaVersion = 1;

class HarnessOptions {
  final String suite;
  final int seed;
  final int samples;
  final int rounds;
  final List<int> sizes;
  final String output;
  final bool diskFull;
  final String? diskFullPath;
  final String? approvedPath;
  final int maxAllocation;

  HarnessOptions(List<String> args)
      : suite = _value(args, 'suite') ?? 'all',
        seed = int.parse(_value(args, 'seed') ?? '5904128'),
        samples = int.parse(_value(args, 'samples') ?? '3'),
        rounds = int.parse(_value(args, 'rounds') ?? '5'),
        sizes = (_value(args, 'sizes-mib') ?? '1,16,128')
            .split(',')
            .map(int.parse)
            .toList(),
        output = _value(args, 'output') ??
            'benchmarks/storage_reliability/results/latest.json',
        diskFull = args.contains('--enable-disk-full'),
        diskFullPath = _value(args, 'disk-full-path'),
        approvedPath = _value(args, 'approve-disk-full-path'),
        maxAllocation =
            int.parse(_value(args, 'max-allocation-mib') ?? '256') * mib {
    const values = {
      'suite',
      'seed',
      'samples',
      'rounds',
      'sizes-mib',
      'output',
      'disk-full-path',
      'approve-disk-full-path',
      'max-allocation-mib'
    };
    for (final arg in args) {
      if (arg == '--enable-disk-full') continue;
      if (!arg.startsWith('--') ||
          !arg.contains('=') ||
          !values.contains(arg.substring(2, arg.indexOf('=')))) {
        throw ArgumentError('Unknown argument: $arg');
      }
    }
    if (!{'all', 'reliability', 'benchmark', 'smoke'}.contains(suite) ||
        samples < 1 ||
        samples > 30 ||
        rounds < 1 ||
        rounds > 25 ||
        sizes.isEmpty ||
        sizes.any((s) => !{1, 16, 128, 1024}.contains(s)) ||
        maxAllocation < 32 * mib ||
        maxAllocation > 512 * mib) {
      throw ArgumentError(
          'Invalid suite or bounded sample/size/allocation options');
    }
  }

  Map<String, Object?> toJson() => {
        'suite': suite,
        'seed': seed,
        'samples': samples,
        'rounds': rounds,
        'sizesMiB': sizes,
        'diskFullOptIn': diskFull,
        'maxAllocationBytes': maxAllocation
      };
}

String? _value(List<String> args, String name) {
  final prefix = '--$name=';
  final matches = args.where((arg) => arg.startsWith(prefix)).toList();
  if (matches.length > 1) throw ArgumentError('Repeated option: $name');
  return matches.isEmpty ? null : matches.single.substring(prefix.length);
}

Map<String, Object?> summarize(List<num> samples) {
  final ordered = samples.map((n) => n.toDouble()).toList()..sort();
  if (ordered.isEmpty) return {'count': 0, 'median': null, 'p95': null};
  final middle = ordered.length ~/ 2;
  return {
    'count': ordered.length,
    'median': ordered.length.isOdd
        ? ordered[middle]
        : (ordered[middle - 1] + ordered[middle]) / 2,
    'p95':
        ordered.length < 20 ? null : ordered[(ordered.length * .95).ceil() - 1],
    'minimum': ordered.first,
    'maximum': ordered.last
  };
}

/// Repeating a seeded incompressible block avoids holding a whole fixture in RAM.
List<int> fixtureBlock(int seed) {
  final random = Random(seed);
  return List<int>.generate(64 * 1024, (_) => random.nextInt(256));
}

void requireCondition(bool condition, String description) {
  if (!condition) throw StateError(description);
}
