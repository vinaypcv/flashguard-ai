import 'dart:math';

class ThroughputSample {
  final Duration elapsed;
  final double mbps;

  const ThroughputSample({required this.elapsed, required this.mbps});
}

class DriveHealthReport {
  final int confidenceScore; // 0 to 100
  final double peakMbps;
  final double averageMbps;
  final bool thermalThrottlingDetected;
  final String diagnosticSummary;

  const DriveHealthReport({
    required this.confidenceScore,
    required this.peakMbps,
    required this.averageMbps,
    required this.thermalThrottlingDetected,
    required this.diagnosticSummary,
  });
}

class TelemetryTracker {
  final List<ThroughputSample> _samples = [];

  List<ThroughputSample> get samples => List.unmodifiable(_samples);

  void recordSample(Duration elapsed, double mbps) {
    if (mbps.isFinite && mbps >= 0) {
      _samples.add(ThroughputSample(elapsed: elapsed, mbps: mbps));
    }
  }

  void reset() => _samples.clear();

  /// Computes a Drive Confidence Score from throughput stability, verified file ratio, and free headroom.
  DriveHealthReport evaluate({
    required int totalFiles,
    required int verifiedFiles,
    required double freeSpaceRatio, // 0.0 to 1.0
  }) {
    final peak =
        _samples.isEmpty ? 0.0 : _samples.map((s) => s.mbps).reduce(max);
    final avg = _samples.isEmpty
        ? 0.0
        : _samples.map((s) => s.mbps).reduce((a, b) => a + b) / _samples.length;

    // Detect thermal cliffing: sustained drop > 45% from peak speed in the trailing third of samples
    bool throttled = false;
    if (_samples.length >= 6 && peak > 10.0) {
      final tailStart = (_samples.length * 0.66).floor();
      final tailSamples = _samples.sublist(tailStart);
      final tailAvg = tailSamples.map((s) => s.mbps).reduce((a, b) => a + b) /
          tailSamples.length;
      if (tailAvg < peak * 0.55) {
        throttled = true;
      }
    }

    // Weighted confidence score:
    // 55% cryptographic/header integrity + 25% thermal stability + 20% wear-leveling free headroom
    final integrityRatio = totalFiles == 0 ? 1.0 : (verifiedFiles / totalFiles);
    final integrityPoints = integrityRatio * 55.0;
    final thermalPoints = throttled ? 10.0 : 25.0;
    final headroomPoints = (freeSpaceRatio.clamp(0.0, 1.0)) * 20.0;

    final score = (integrityPoints + thermalPoints + headroomPoints)
        .round()
        .clamp(0, 100)
        .toInt();

    final summary = switch ((
      verifiedFiles < totalFiles,
      throttled,
      freeSpaceRatio < 0.10,
    )) {
      (true, _, _) =>
        'Action Required: ${totalFiles - verifiedFiles} file(s) failed header/SHA-256 verification. Do not erase source card.',
      (false, true, _) =>
        'All files cryptographically verified, but sustained write speed dropped >45% (thermal throttling detected).',
      (false, false, true) =>
        'All files verified. Drive free space is below 10%, which may reduce flash wear-leveling efficiency.',
      _ =>
        'All copied files passed the available checks. Keep originals until independently reviewed.',
    };

    return DriveHealthReport(
      confidenceScore: score,
      peakMbps: peak,
      averageMbps: avg,
      thermalThrottlingDetected: throttled,
      diagnosticSummary: summary,
    );
  }
}
