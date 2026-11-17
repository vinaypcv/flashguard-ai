import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'integrity_engine.dart';
import 'perceptual_dedup.dart';
import 'storage_provider.dart';
import 'telemetry_tracker.dart';

class BatchOffloadSummary {
  final List<FileAuditResult> results;
  final Map<String, List<String>> duplicateGroups;
  final List<MediaIntelligenceTag> mediaTags;
  final DriveHealthReport healthReport;
  final List<BatchFileFailure> failures;
  final int totalFiles;
  final bool cancelled;

  const BatchOffloadSummary({
    required this.results,
    required this.duplicateGroups,
    required this.mediaTags,
    required this.healthReport,
    this.failures = const [],
    this.totalFiles = 0,
    this.cancelled = false,
  });
}

class BatchFileFailure {
  final String relativePath;
  final String message;

  const BatchFileFailure({required this.relativePath, required this.message});
}

enum BatchProgressState {
  transferring,
  paused,
  resumed,
  fileComplete,
  fileFailed
}

class BatchProgressEvent {
  final String relativePath;
  final int fileIndex;
  final int totalFiles;
  final int bytesCopied;
  final int totalBytes;
  final BatchProgressState state;

  const BatchProgressEvent({
    required this.relativePath,
    required this.fileIndex,
    required this.totalFiles,
    required this.bytesCopied,
    required this.totalBytes,
    required this.state,
  });

  double get fraction => totalBytes == 0 ? 1 : bytesCopied / totalBytes;
}

/// Deterministic storage faults used by tests and the local chaos demo.
/// Keys are source-relative paths; byte thresholds run after a saved block.
/// Disk-full injection leaves a torn tail, and termination exits only the
/// worker isolate (it does not simulate killing the operating-system process).
class BatchFaultInjection {
  final Map<String, int> failAfterBytes;
  final Set<String> failBeforeTransfer;
  final Map<String, int> diskFullAfterBytes;
  final Map<String, int> corruptPartAfterBytes;
  final Map<String, int> corruptCheckpointAfterBytes;
  final Map<String, int> terminateAfterBytes;
  final int chunkDelayMs;

  const BatchFaultInjection({
    this.failAfterBytes = const {},
    this.failBeforeTransfer = const {},
    this.diskFullAfterBytes = const {},
    this.corruptPartAfterBytes = const {},
    this.corruptCheckpointAfterBytes = const {},
    this.terminateAfterBytes = const {},
    this.chunkDelayMs = 0,
  });
}

class BatchOffloadJob {
  final Future<BatchOffloadSummary> done;
  final Stream<BatchProgressEvent> progress;
  final SendPort _control;

  const BatchOffloadJob._({
    required this.done,
    required this.progress,
    required SendPort control,
  }) : _control = control;

  void pause() => _control.send('pause');
  void resume() => _control.send('resume');
  void cancel() => _control.send('cancel');
}

class IsolateOffloadWorker {
  /// Starts a recursive batch and returns a live progress/control handle.
  static Future<BatchOffloadJob> startVerifiedBatch({
    required String sourceDirPath,
    required String destDirPath,
    double freeSpaceRatio = SimulatedVolumeProvider.defaultFreeSpaceRatio,
    int checkpointBlockBytes = 4 * 1024 * 1024,
    BatchFaultInjection faultInjection = const BatchFaultInjection(),
  }) async {
    final receivePort = ReceivePort();
    final exitPort = ReceivePort();
    final ready = Completer<SendPort>();
    final done = Completer<BatchOffloadSummary>();
    final progress = StreamController<BatchProgressEvent>();

    exitPort.listen((_) {
      // The worker can exit immediately after sending its final message. Give
      // the normal event queue a turn before treating an exit as unexpected.
      Timer.run(() {
        if (done.isCompleted) return;
        final error = StateError(
          'Batch worker exited before reporting completion.',
        );
        if (!ready.isCompleted) ready.completeError(error);
        if (!done.isCompleted) done.completeError(error);
        progress.close();
        receivePort.close();
        exitPort.close();
      });
    });

    receivePort.listen((dynamic message) {
      final event = Map<Object?, Object?>.from(message as Map);
      switch (event['type']) {
        case 'ready':
          if (!ready.isCompleted) ready.complete(event['control'] as SendPort);
          break;
        case 'progress':
          progress.add(BatchProgressEvent(
            relativePath: event['path'] as String,
            fileIndex: event['index'] as int,
            totalFiles: event['count'] as int,
            bytesCopied: event['bytes'] as int,
            totalBytes: event['totalBytes'] as int,
            state: BatchProgressState.values.byName(event['state'] as String),
          ));
          break;
        case 'done':
          if (!done.isCompleted) {
            done.complete(event['summary'] as BatchOffloadSummary);
          }
          progress.close();
          receivePort.close();
          exitPort.close();
          break;
        case 'fatal':
          if (!done.isCompleted) {
            done.completeError(StateError(event['message'] as String));
          }
          progress.close();
          receivePort.close();
          exitPort.close();
          break;
      }
    });

    try {
      await Isolate.spawn<Map<String, Object?>>(
        _runBatchIsolate,
        {
          'source': sourceDirPath,
          'destination': destDirPath,
          'freeSpaceRatio': freeSpaceRatio,
          'checkpointBlockBytes': checkpointBlockBytes,
          'failAfterBytes': faultInjection.failAfterBytes,
          'failBeforeTransfer': faultInjection.failBeforeTransfer.toList(),
          'diskFullAfterBytes': faultInjection.diskFullAfterBytes,
          'corruptPartAfterBytes': faultInjection.corruptPartAfterBytes,
          'corruptCheckpointAfterBytes':
              faultInjection.corruptCheckpointAfterBytes,
          'terminateAfterBytes': faultInjection.terminateAfterBytes,
          'chunkDelayMs': faultInjection.chunkDelayMs,
          'events': receivePort.sendPort,
        },
        onExit: exitPort.sendPort,
      );
      final control = await ready.future;
      return BatchOffloadJob._(
        done: done.future,
        progress: progress.stream,
        control: control,
      );
    } catch (_) {
      receivePort.close();
      exitPort.close();
      await progress.close();
      rethrow;
    }
  }

  /// Compatibility API for callers that only need the completed summary.
  static Future<BatchOffloadSummary> runVerifiedBatch({
    required String sourceDirPath,
    required String destDirPath,
    double freeSpaceRatio = SimulatedVolumeProvider.defaultFreeSpaceRatio,
  }) async {
    final job = await startVerifiedBatch(
      sourceDirPath: sourceDirPath,
      destDirPath: destDirPath,
      freeSpaceRatio: freeSpaceRatio,
    );
    return job.done;
  }
}

Future<void> _runBatchIsolate(Map<String, Object?> request) async {
  final events = request['events']! as SendPort;
  final controlPort = ReceivePort();
  final control = _BatchControl(events);
  controlPort.listen(control.handleMessage);
  events.send({'type': 'ready', 'control': controlPort.sendPort});

  try {
    final sourceDir = Directory(request['source']! as String);
    final destinationRoot = Directory(request['destination']! as String);
    if (_isSameOrChildPath(
        sourceDir.absolute.path, destinationRoot.absolute.path)) {
      throw ArgumentError(
        'The destination must be outside the source directory for recursive batches.',
      );
    }
    if (!await destinationRoot.exists()) {
      await destinationRoot.create(recursive: true);
    }

    final sourceRootPath = sourceDir.absolute.path;
    final tracker = TelemetryTracker();
    final batchStopwatch = Stopwatch()..start();
    final results = <FileAuditResult>[];
    final failures = <BatchFileFailure>[];
    final hashToFiles = <String, List<String>>{};
    final entities = await sourceDir
        .list(recursive: true, followLinks: false)
        .where((entity) => entity is File)
        .cast<File>()
        .toList();
    entities.sort((a, b) => a.path.compareTo(b.path));

    bool cancelled = false;
    for (var index = 0; index < entities.length; index++) {
      final file = entities[index];
      final relativePath =
          _relativeFilePath(sourceRootPath, file.absolute.path);
      final normalizedPath = _normalizeRelativePath(relativePath);
      try {
        final fileSize = await file.length();
        await control.waitAtCheckpoint(
          path: relativePath,
          index: index + 1,
          count: entities.length,
          bytes: 0,
          totalBytes: fileSize,
        );
        if ((request['failBeforeTransfer']! as List).contains(normalizedPath)) {
          throw FileSystemException('Injected permission denied', file.path);
        }

        final relativeDirectory = _relativeDirectory(relativePath);
        final destinationDir = relativeDirectory.isEmpty
            ? destinationRoot
            : Directory(
                '${destinationRoot.path}${Platform.pathSeparator}$relativeDirectory',
              );
        if (!await destinationDir.exists()) {
          await destinationDir.create(recursive: true);
        }

        var injectedInterruption = false;
        var injectedDiskFull = false;
        var injectedPartCorruption = false;
        var injectedCheckpointCorruption = false;
        final failAfterBytes =
            (request['failAfterBytes']! as Map)[normalizedPath] as int?;
        final diskFullAfterBytes =
            (request['diskFullAfterBytes']! as Map)[normalizedPath] as int?;
        final corruptPartAfterBytes =
            (request['corruptPartAfterBytes']! as Map)[normalizedPath] as int?;
        final corruptCheckpointAfterBytes =
            (request['corruptCheckpointAfterBytes']! as Map)[normalizedPath]
                as int?;
        final terminateAfterBytes =
            (request['terminateAfterBytes']! as Map)[normalizedPath] as int?;
        final partFile = File(
          '${destinationDir.path}${Platform.pathSeparator}'
          '${file.uri.pathSegments.last}.part',
        );
        final checkpointFile = File(
          '${destinationDir.path}${Platform.pathSeparator}'
          '${file.uri.pathSegments.last}.checkpoint.json',
        );
        final audit = await IntegrityEngine.verifiedOffload(
          source: file,
          destinationDir: destinationDir,
          checkpointBlockBytes: request['checkpointBlockBytes']! as int,
          onProgress: (fraction) async {
            final bytes = (fraction * fileSize).round();
            control.sendProgress(
              path: relativePath,
              index: index + 1,
              count: entities.length,
              bytes: bytes,
              totalBytes: fileSize,
              state: BatchProgressState.transferring,
            );
            if (!injectedInterruption &&
                failAfterBytes != null &&
                bytes >= failAfterBytes) {
              injectedInterruption = true;
              throw FileSystemException(
                  'Injected transfer interruption', file.path);
            }
            if (!injectedDiskFull &&
                diskFullAfterBytes != null &&
                bytes >= diskFullAfterBytes) {
              injectedDiskFull = true;
              // Preserve an uncheckpointed tail to model a write that ran out
              // of space between block boundaries. Recovery must truncate it.
              await partFile.writeAsBytes(
                List<int>.filled(17, 0xee),
                mode: FileMode.append,
              );
              throw FileSystemException(
                'Injected disk full after $bytes bytes',
                file.path,
              );
            }
            if (!injectedPartCorruption &&
                corruptPartAfterBytes != null &&
                bytes >= corruptPartAfterBytes) {
              injectedPartCorruption = true;
              await _flipFirstByte(partFile);
            }
            if (!injectedCheckpointCorruption &&
                corruptCheckpointAfterBytes != null &&
                bytes >= corruptCheckpointAfterBytes) {
              injectedCheckpointCorruption = true;
              await checkpointFile.writeAsString('{torn checkpoint');
              throw FileSystemException(
                'Injected checkpoint corruption after $bytes bytes',
                checkpointFile.path,
              );
            }
            if (terminateAfterBytes != null && bytes >= terminateAfterBytes) {
              // Let the transfer engine close its handles, then exit before
              // the batch can report a completed summary.
              throw const _InjectedWorkerTermination();
            }
            final delayMs = request['chunkDelayMs']! as int;
            if (delayMs > 0) {
              await Future<void>.delayed(Duration(milliseconds: delayMs));
            }
            await control.waitAtCheckpoint(
              path: relativePath,
              index: index + 1,
              count: entities.length,
              bytes: bytes,
              totalBytes: fileSize,
            );
          },
        );
        final relativeAudit = audit.withRelativePath(relativePath);
        results.add(relativeAudit);
        tracker.recordSample(batchStopwatch.elapsed, audit.transferMbps);
        hashToFiles.putIfAbsent(audit.sha256Hash, () => []).add(audit.fileName);
        control.sendProgress(
          path: relativePath,
          index: index + 1,
          count: entities.length,
          bytes: audit.byteSize,
          totalBytes: audit.byteSize,
          state: BatchProgressState.fileComplete,
        );
      } on _InjectedWorkerTermination {
        // Simulate an abrupt worker loss after the current checkpoint while
        // avoiding an OS-level process kill in the test runner.
        Isolate.exit();
      } on _BatchCancelled {
        cancelled = true;
        break;
      } catch (error) {
        failures.add(BatchFileFailure(
          relativePath: relativePath,
          message: error.toString(),
        ));
        control.sendProgress(
          path: relativePath,
          index: index + 1,
          count: entities.length,
          bytes: 0,
          totalBytes: 0,
          state: BatchProgressState.fileFailed,
        );
      }
    }

    final duplicates = Map<String, List<String>>.fromEntries(
      hashToFiles.entries.where((entry) => entry.value.length > 1),
    );
    final duplicateCopies = <String>{
      for (final paths in duplicates.values) ...paths.skip(1),
    };
    final mediaTags = cancelled
        ? const <MediaIntelligenceTag>[]
        : await OfflineMediaIntelligence.analyzeDirectory(
            entities,
            skipSimilarMatchNames: duplicateCopies,
          );
    final verifiedCount =
        results.where((result) => result.byteForByteVerified).length;
    final healthReport = tracker.evaluate(
      totalFiles: entities.length,
      verifiedFiles: verifiedCount,
      freeSpaceRatio: request['freeSpaceRatio']! as double,
    );

    events.send({
      'type': 'done',
      'summary': BatchOffloadSummary(
        results: results,
        duplicateGroups: duplicates,
        mediaTags: mediaTags,
        healthReport: healthReport,
        failures: failures,
        totalFiles: entities.length,
        cancelled: cancelled,
      ),
    });
  } catch (error) {
    events.send({'type': 'fatal', 'message': error.toString()});
  } finally {
    controlPort.close();
  }
}

class _BatchControl {
  final SendPort _events;
  bool _paused = false;
  bool _cancelled = false;
  Completer<void>? _resumeGate;

  _BatchControl(this._events);

  void handleMessage(dynamic message) {
    switch (message) {
      case 'pause':
        _paused = true;
        _resumeGate ??= Completer<void>();
        break;
      case 'resume':
        _paused = false;
        final gate = _resumeGate;
        _resumeGate = null;
        if (gate != null && !gate.isCompleted) gate.complete();
        break;
      case 'cancel':
        _cancelled = true;
        final gate = _resumeGate;
        _resumeGate = null;
        if (gate != null && !gate.isCompleted) gate.complete();
        break;
    }
  }

  Future<void> waitAtCheckpoint({
    required String path,
    required int index,
    required int count,
    required int bytes,
    required int totalBytes,
  }) async {
    if (_cancelled) throw const _BatchCancelled();
    if (_paused) {
      sendProgress(
        path: path,
        index: index,
        count: count,
        bytes: bytes,
        totalBytes: totalBytes,
        state: BatchProgressState.paused,
      );
      await _resumeGate!.future;
      if (_cancelled) throw const _BatchCancelled();
      sendProgress(
        path: path,
        index: index,
        count: count,
        bytes: bytes,
        totalBytes: totalBytes,
        state: BatchProgressState.resumed,
      );
    }
  }

  void sendProgress({
    required String path,
    required int index,
    required int count,
    required int bytes,
    required int totalBytes,
    required BatchProgressState state,
  }) {
    _events.send({
      'type': 'progress',
      'path': path,
      'index': index,
      'count': count,
      'bytes': bytes,
      'totalBytes': totalBytes,
      'state': state.name,
    });
  }
}

class _BatchCancelled implements Exception {
  const _BatchCancelled();
}

class _InjectedWorkerTermination implements Exception {
  const _InjectedWorkerTermination();
}

Future<void> _flipFirstByte(File file) async {
  if (await file.length() == 0) {
    throw FileSystemException(
        'Cannot corrupt an empty partial file', file.path);
  }
  final reader = await file.open(mode: FileMode.read);
  late final int originalByte;
  try {
    originalByte = await reader.readByte();
  } finally {
    await reader.close();
  }

  final writer = await file.open(mode: FileMode.writeOnly);
  try {
    await writer.setPosition(0);
    await writer.writeByte(originalByte ^ 1);
    await writer.flush();
  } finally {
    await writer.close();
  }
}

String _relativeFilePath(String sourceRoot, String absoluteFilePath) {
  final prefix = sourceRoot.endsWith(Platform.pathSeparator)
      ? sourceRoot
      : '$sourceRoot${Platform.pathSeparator}';
  final pathMatches = Platform.isWindows
      ? absoluteFilePath.toLowerCase().startsWith(prefix.toLowerCase())
      : absoluteFilePath.startsWith(prefix);
  if (!pathMatches) {
    throw FileSystemException(
        'File is outside the selected source directory', absoluteFilePath);
  }
  return absoluteFilePath
      .substring(prefix.length)
      .replaceAll(Platform.pathSeparator, '/');
}

bool _isSameOrChildPath(String root, String candidate) {
  String normalize(String path) {
    var value =
        Directory(path).absolute.path.replaceAll('/', Platform.pathSeparator);
    while (value.length > 1 &&
        value.endsWith(Platform.pathSeparator) &&
        !(Platform.isWindows && value.length == 3)) {
      value = value.substring(0, value.length - 1);
    }
    return Platform.isWindows ? value.toLowerCase() : value;
  }

  final normalizedRoot = normalize(root);
  final normalizedCandidate = normalize(candidate);
  if (normalizedRoot == normalizedCandidate) return true;
  final prefix = normalizedRoot.endsWith(Platform.pathSeparator)
      ? normalizedRoot
      : '$normalizedRoot${Platform.pathSeparator}';
  return normalizedCandidate.startsWith(prefix);
}

String _relativeDirectory(String relativePath) {
  final separator = relativePath.lastIndexOf('/');
  return separator < 0
      ? ''
      : relativePath
          .substring(0, separator)
          .replaceAll('/', Platform.pathSeparator);
}

String _normalizeRelativePath(String path) => path.replaceAll('\\', '/');
