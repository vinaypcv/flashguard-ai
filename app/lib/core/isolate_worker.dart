import 'dart:io';
import 'dart:isolate';

import 'integrity_engine.dart';
import 'perceptual_dedup.dart';
import 'storage_provider.dart';
import 'telemetry_tracker.dart';

class BatchOffloadSummary {
  final List<FileAuditResult> results;
  final Map<String, List<String>>
      duplicateGroups; // sha256 -> list of filenames
  final List<MediaIntelligenceTag> mediaTags;
  final DriveHealthReport healthReport;

  const BatchOffloadSummary({
    required this.results,
    required this.duplicateGroups,
    required this.mediaTags,
    required this.healthReport,
  });
}

class IsolateOffloadWorker {
  /// Executes full directory triage, deduplication, and SHA-256 verified transfer off the UI isolate.
  static Future<BatchOffloadSummary> runVerifiedBatch({
    required String sourceDirPath,
    required String destDirPath,
    double freeSpaceRatio = SimulatedVolumeProvider.defaultFreeSpaceRatio,
  }) {
    return Isolate.run(() async {
      final sourceDir = Directory(sourceDirPath);
      final destDir = Directory(destDirPath);
      if (!await destDir.exists()) {
        await destDir.create(recursive: true);
      }

      final tracker = TelemetryTracker();
      final batchStopwatch = Stopwatch()..start();
      final results = <FileAuditResult>[];
      final hashToFiles = <String, List<String>>{};

      final entities = await sourceDir
          .list(followLinks: false)
          .where((e) => e is File)
          .cast<File>()
          .toList();

      entities.sort((a, b) => a.path.compareTo(b.path));

      for (final file in entities) {
        final audit = await IntegrityEngine.verifiedOffload(
          source: file,
          destinationDir: destDir,
        );
        results.add(audit);
        tracker.recordSample(batchStopwatch.elapsed, audit.transferMbps);
        hashToFiles.putIfAbsent(audit.sha256Hash, () => []).add(audit.fileName);
      }

      final duplicates = Map<String, List<String>>.fromEntries(
        hashToFiles.entries.where((entry) => entry.value.length > 1),
      );
      final duplicateCopies = <String>{
        for (final names in duplicates.values) ...names.skip(1),
      };
      final mediaTags = await OfflineMediaIntelligence.analyzeDirectory(
        entities,
        skipSimilarMatchNames: duplicateCopies,
      );

      final verifiedCount = results.where((r) => r.isCopyVerified).length;
      final healthReport = tracker.evaluate(
        totalFiles: results.length,
        verifiedFiles: verifiedCount,
        freeSpaceRatio: freeSpaceRatio,
      );

      return BatchOffloadSummary(
        results: results,
        duplicateGroups: duplicates,
        mediaTags: mediaTags,
        healthReport: healthReport,
      );
    });
  }
}
