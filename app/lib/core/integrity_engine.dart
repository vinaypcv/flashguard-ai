import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'atomic_file_promoter.dart';
import 'transfer_diagnostics.dart';
import 'transfer_state_machine.dart';

enum MediaIntegrityStatus {
  valid,
  corruptedHeader,
  truncatedContainer,
  ioError,
}

class FileAuditResult {
  final String fileName;

  /// Path relative to the selected source directory for batch transfers.
  /// Direct single-file transfers default this to [fileName].
  final String relativePath;
  final String destinationFileName;
  final int byteSize;
  final String sha256Hash;

  /// Structural result from the lightweight media container inspection.
  final MediaIntegrityStatus mediaStatus;

  /// True only because an audit result is returned after source and destination
  /// SHA-256 digests have matched and the verified part has been promoted.
  final bool byteForByteVerified;
  final double transferMbps;
  final int resumedBytes;
  final int transferredBytes;
  final bool reusedExistingCopy;
  final StorageCommitEvidence? storageCommitEvidence;

  const FileAuditResult({
    required this.fileName,
    required this.destinationFileName,
    required this.byteSize,
    required this.sha256Hash,
    required this.mediaStatus,
    required this.byteForByteVerified,
    required this.transferMbps,
    String? relativePath,
    this.resumedBytes = 0,
    this.transferredBytes = 0,
    this.reusedExistingCopy = false,
    this.storageCommitEvidence,
  }) : relativePath = relativePath ?? fileName;

  FileAuditResult withRelativePath(String path) => FileAuditResult(
        fileName: fileName,
        destinationFileName: destinationFileName,
        byteSize: byteSize,
        sha256Hash: sha256Hash,
        mediaStatus: mediaStatus,
        byteForByteVerified: byteForByteVerified,
        transferMbps: transferMbps,
        relativePath: path,
        resumedBytes: resumedBytes,
        transferredBytes: transferredBytes,
        reusedExistingCopy: reusedExistingCopy,
        storageCommitEvidence: storageCommitEvidence,
      );

  /// Compatibility alias for callers that previously read the media status.
  @Deprecated('Use mediaStatus to describe structure or byteForByteVerified')
  MediaIntegrityStatus get status => mediaStatus;

  @Deprecated('Use byteForByteVerified')
  bool get isCopyVerified => byteForByteVerified;

  bool get isMediaStructurallyValid =>
      mediaStatus == MediaIntegrityStatus.valid;

  String get mediaIntegrityLabel => switch (mediaStatus) {
        MediaIntegrityStatus.valid => 'VALID',
        MediaIntegrityStatus.corruptedHeader => 'CORRUPTED HEADER',
        MediaIntegrityStatus.truncatedContainer => 'TRUNCATED CONTAINER',
        MediaIntegrityStatus.ioError => 'INSPECTION ERROR',
      };

  String? get resumeMessage => reusedExistingCopy
      ? 'Existing copy reverified (0 bytes transferred)'
      : resumedBytes == 0 || byteSize == 0
          ? null
          : 'Resumed from ${(resumedBytes * 100 / byteSize).round()}% '
              '($resumedBytes bytes reused)';
}

class IntegrityEngine {
  /// Checks JPEG boundaries or complete top-level MP4/MOV boxes.
  static Future<MediaIntegrityStatus> inspectMediaHeader(
    File file, {
    String? mediaName,
  }) async {
    try {
      final length = await file.length();
      final lowerName = (mediaName ?? file.path).toLowerCase();
      final raf = await file.open(mode: FileMode.read);
      try {
        if (lowerName.endsWith('.jpg') || lowerName.endsWith('.jpeg')) {
          if (length < 4) return MediaIntegrityStatus.corruptedHeader;
          final head = await raf.read(2);
          await raf.setPosition(length - 2);
          final tail = await raf.read(2);
          if (head.length != 2 || head[0] != 0xff || head[1] != 0xd8) {
            return MediaIntegrityStatus.corruptedHeader;
          }
          return tail.length == 2 && tail[0] == 0xff && tail[1] == 0xd9
              ? MediaIntegrityStatus.valid
              : MediaIntegrityStatus.truncatedContainer;
        }
        if (lowerName.endsWith('.mp4') || lowerName.endsWith('.mov')) {
          if (length < 16) return MediaIntegrityStatus.corruptedHeader;
          var offset = 0;
          var hasMoov = false;
          while (offset < length) {
            await raf.setPosition(offset);
            final header = await raf.read(8);
            if (header.length != 8) {
              return MediaIntegrityStatus.truncatedContainer;
            }
            final type = String.fromCharCodes(header.sublist(4, 8));
            final size32 = _uint32(header, 0);
            var boxSize = size32;
            var headerSize = 8;
            if (size32 == 1) {
              final extended = await raf.read(8);
              if (extended.length != 8) {
                return MediaIntegrityStatus.truncatedContainer;
              }
              boxSize = (_uint32(extended, 0) << 32) | _uint32(extended, 4);
              headerSize = 16;
            } else if (size32 == 0) {
              boxSize = length - offset;
            }
            if (offset == 0 && type != 'ftyp') {
              return MediaIntegrityStatus.corruptedHeader;
            }
            if (boxSize < headerSize || boxSize > length - offset) {
              return MediaIntegrityStatus.truncatedContainer;
            }
            if (type == 'moov') hasMoov = true;
            offset += boxSize;
          }
          return hasMoov
              ? MediaIntegrityStatus.valid
              : MediaIntegrityStatus.truncatedContainer;
        }
        return MediaIntegrityStatus.corruptedHeader;
      } finally {
        await raf.close();
      }
    } on FileSystemException {
      return MediaIntegrityStatus.ioError;
    }
  }

  /// Checkpoints complete blocks. A resumed run re-hashes the source and every
  /// saved source/destination block before trusting a prior `.part` file.
  static Future<FileAuditResult> verifiedOffload({
    required File source,
    required Directory destinationDir,
    Directory? destinationRoot,
    TransferStateMachine? lifecycle,
    AtomicFilePromoter promoter = const NativeAtomicFilePromoter(),
    TransferDiagnostics? diagnostics,
    FutureOr<void> Function(TransferProbe probe)? onProbe,
    FutureOr<void> Function()? beforePromotion,
    FutureOr<void> Function()? afterPromotion,
    FutureOr<void> Function(double progress)? onProgress,
    String? expectedSha256,
    int checkpointBlockBytes = 4 * 1024 * 1024,
  }) async {
    if (checkpointBlockBytes <= 0) {
      throw ArgumentError.value(checkpointBlockBytes, 'checkpointBlockBytes');
    }
    final timer = Stopwatch()..start();
    final metrics = diagnostics ?? TransferDiagnostics();
    final state = lifecycle ?? TransferStateMachine();
    final fileName = source.uri.pathSegments.last;
    late final File finalFile;
    late final File tempFile;
    late final File checkpointFile;
    late final File checkpointBackupFile;
    late final File checkpointStagingFile;
    RandomAccessFile? output;
    TransferWorkspaceLease? workspaceLease;
    var discardPartial = false;
    var pathsReady = false;
    try {
      await _validateDestination(
          destinationRoot ?? destinationDir, destinationDir);
      if (!await destinationDir.exists()) {
        await destinationDir.create(recursive: true);
      }
      await _validateDestination(
          destinationRoot ?? destinationDir, destinationDir);
      state.transition(TransferState.hashingSource);
      final totalBytes = await source.length();
      final sourceHashTimer = Stopwatch()..start();
      final sourceDigest =
          (await sha256.bind(source.openRead()).single).toString();
      metrics.sourceHashMicros = sourceHashTimer.elapsedMicroseconds;
      if (expectedSha256 != null &&
          sourceDigest != expectedSha256.toLowerCase()) {
        throw FileSystemException(
            'Source SHA-256 differs from trusted digest', source.path);
      }

      // Reuse a matching copy, or preserve conflicts under the first available
      // numbered name. This keeps retries idempotent without overwriting data.
      var copyNumber = 1;
      while (true) {
        final candidateName = copyNumber == 1
            ? fileName
            : _fileNameWithCopyNumber(fileName, copyNumber);
        final candidate = File(
          '${destinationDir.path}${Platform.pathSeparator}$candidateName',
        );
        if (await FileSystemEntity.type(candidate.path, followLinks: false) ==
            FileSystemEntityType.link) {
          throw FileSystemException(
              'Destination is a symbolic link', candidate.path);
        }
        if (await candidate.exists()) {
          final existingResult = await _reuseExistingCopy(
            source: source,
            candidate: candidate,
            fileName: fileName,
            totalBytes: totalBytes,
            sourceDigest: sourceDigest,
          );
          if (existingResult != null) {
            state.transition(TransferState.verifying);
            state.transition(TransferState.committed);
            return existingResult;
          }
          copyNumber++;
          continue;
        }
        finalFile = candidate;
        break;
      }

      final capabilities = await promoter.capabilities(destinationDir);
      if (!capabilities.atomicNoReplace) {
        throw PromotionException(PromotionFailure.unsupported,
            capabilities.description, finalFile.path);
      }
      workspaceLease = await promoter.acquireWorkspace(finalFile);

      tempFile = File('${finalFile.path}.part');
      checkpointFile = File('${finalFile.path}.checkpoint.json');
      checkpointBackupFile = File('${checkpointFile.path}.bak');
      checkpointStagingFile = File('${checkpointFile.path}.tmp');
      pathsReady = true;
      for (final file in [
        finalFile,
        tempFile,
        checkpointFile,
        checkpointBackupFile,
        checkpointStagingFile
      ]) {
        if (await FileSystemEntity.type(file.path, followLinks: false) ==
            FileSystemEntityType.link) {
          throw FileSystemException(
              'Destination sidecar is a symbolic link', file.path);
        }
      }

      var resumedBytes = 0;
      final recoveryTimer = Stopwatch()..start();
      var blockHashes = <String>[];
      final checkpointFiles = [checkpointFile, checkpointBackupFile];
      final checkpointCandidates = <Map<String, dynamic>>[];
      for (final candidateFile in checkpointFiles) {
        if (!await candidateFile.exists()) continue;
        final candidate = await _readCheckpoint(candidateFile);
        if (candidate != null &&
            candidate['sourcePath'] == source.absolute.path &&
            candidate['sourceBytes'] == totalBytes &&
            candidate['sourceSha256'] == sourceDigest &&
            candidate['blockBytes'] == checkpointBlockBytes) {
          candidate['_journalPath'] = candidateFile.path;
          checkpointCandidates.add(candidate);
        }
      }
      checkpointCandidates.sort(
          (a, b) => (b['generation'] as int).compareTo(a['generation'] as int));

      var checkpointResumed = false;
      if (await tempFile.exists()) {
        for (final checkpoint in checkpointCandidates) {
          final offset = checkpoint['offset'] as int;
          final savedHashes =
              (checkpoint['blockSha256'] as List).cast<String>();
          if (offset < 0 ||
              offset > totalBytes ||
              savedHashes.length != (offset / checkpointBlockBytes).ceil() ||
              await tempFile.length() < offset) {
            continue;
          }

          final sourceReader = await source.open();
          final partReader = await tempFile.open();
          var blocksMatch = true;
          try {
            for (var i = 0; i < savedHashes.length; i++) {
              final count = (offset - i * checkpointBlockBytes)
                  .clamp(0, checkpointBlockBytes);
              final srcBlock = await sourceReader.read(count);
              final dstBlock = await partReader.read(count);
              if (srcBlock.length != count ||
                  dstBlock.length != count ||
                  sha256.convert(srcBlock).toString() != savedHashes[i] ||
                  sha256.convert(dstBlock).toString() != savedHashes[i]) {
                blocksMatch = false;
                break;
              }
            }
          } finally {
            await sourceReader.close();
            await partReader.close();
          }
          if (!blocksMatch) continue;

          resumedBytes = offset;
          blockHashes = savedHashes;
          checkpointResumed = true;

          // If the newest usable snapshot was the backup, restore it as the
          // primary before the next write rotates journal generations.
          if (checkpoint['_journalPath'] == checkpointBackupFile.path) {
            if (await checkpointFile.exists()) await checkpointFile.delete();
            await checkpointBackupFile.rename(checkpointFile.path);
            checkpointCandidates
              ..clear()
              ..add({
                'generation': checkpoint['generation'],
                'sourcePath': checkpoint['sourcePath'],
                'sourceBytes': checkpoint['sourceBytes'],
                'sourceSha256': checkpoint['sourceSha256'],
                'blockBytes': checkpoint['blockBytes'],
                'offset': offset,
                'blockSha256': List<String>.from(savedHashes),
              });
          }
          break;
        }
      }

      if (!checkpointResumed) {
        if (await tempFile.exists()) await tempFile.delete();
        for (final file in [...checkpointFiles, checkpointStagingFile]) {
          if (await file.exists()) await file.delete();
        }
        checkpointCandidates.clear();
      } else if (await checkpointStagingFile.exists()) {
        // A staged snapshot was never promoted; the active or backup snapshot
        // is the recovery point, so discard the incomplete staging file.
        await checkpointStagingFile.delete();
      }

      output = await tempFile.open(mode: FileMode.append);
      metrics.recoveryValidationMicros = recoveryTimer.elapsedMicroseconds;
      state.transition(TransferState.copying);
      await output.truncate(resumedBytes);
      await output.setPosition(resumedBytes);
      final input = await source.open();
      final copyTimer = Stopwatch()..start();
      var copiedBytes = resumedBytes;
      try {
        await input.setPosition(resumedBytes);
        while (copiedBytes < totalBytes) {
          final chunk = await input.read(
            (totalBytes - copiedBytes).clamp(0, checkpointBlockBytes),
          );
          if (chunk.isEmpty) {
            throw FileSystemException(
                'Source ended during transfer', source.path);
          }
          await output.writeFrom(chunk);
          await output.flush();
          metrics.copyBytesWritten += chunk.length;
          await onProbe?.call(TransferProbe(
              TransferProbeStage.blockFlushed, copiedBytes + chunk.length));
          blockHashes.add(sha256.convert(chunk).toString());
          copiedBytes += chunk.length;
          final previousGeneration = checkpointCandidates.isEmpty
              ? 0
              : checkpointCandidates
                  .map((checkpoint) => checkpoint['generation'] as int)
                  .reduce((a, b) => a > b ? a : b);
          metrics.checkpointMetadataBytesWritten += await _writeCheckpoint(
            checkpointFile: checkpointFile,
            backupFile: checkpointBackupFile,
            stagingFile: checkpointStagingFile,
            checkpoint: {
              'version': 2,
              'generation': previousGeneration + 1,
              'sourcePath': source.absolute.path,
              'sourceBytes': totalBytes,
              'sourceSha256': sourceDigest,
              'blockBytes': checkpointBlockBytes,
              'offset': copiedBytes,
              'blockSha256': blockHashes,
            },
          );
          checkpointCandidates
            ..clear()
            ..add({
              'version': 2,
              'generation': previousGeneration + 1,
              'sourcePath': source.absolute.path,
              'sourceBytes': totalBytes,
              'sourceSha256': sourceDigest,
              'blockBytes': checkpointBlockBytes,
              'offset': copiedBytes,
              'blockSha256': List<String>.from(blockHashes),
            });
          state.transition(TransferState.checkpointed);
          await onProbe?.call(
              TransferProbe(TransferProbeStage.checkpointSaved, copiedBytes));
          if (totalBytes > 0) await onProgress?.call(copiedBytes / totalBytes);
          if (copiedBytes < totalBytes &&
              state.state == TransferState.checkpointed) {
            state.transition(TransferState.copying);
          }
        }
      } finally {
        await input.close();
      }
      await output.flush();
      await output.close();
      output = null;
      metrics.copyCheckpointMicros = copyTimer.elapsedMicroseconds;
      state.transition(TransferState.verifying);
      await onProbe?.call(
          TransferProbe(TransferProbeStage.verificationStarted, copiedBytes));
      final verificationTimer = Stopwatch()..start();

      final destinationDigest =
          (await sha256.bind(_verificationStream(tempFile, onProbe)).single)
              .toString();
      final currentSourceDigest =
          (await sha256.bind(source.openRead()).single).toString();
      if (copiedBytes != totalBytes ||
          await source.length() != totalBytes ||
          destinationDigest != sourceDigest ||
          currentSourceDigest != sourceDigest) {
        discardPartial = true;
        throw FileSystemException(
          'Source changed or SHA-256 mismatch',
          source.path,
        );
      }
      final status = await inspectMediaHeader(tempFile, mediaName: fileName);
      if (status == MediaIntegrityStatus.ioError) {
        throw FileSystemException('Media inspection failed', tempFile.path);
      }
      metrics.verificationMicros = verificationTimer.elapsedMicroseconds;
      await onProbe
          ?.call(TransferProbe(TransferProbeStage.bytesVerified, copiedBytes));
      // Complete the data and journal sync requests before the namespace move.
      // Windows reports the missing directory-sync capability explicitly.
      if (capabilities.nativeFileSync) {
        await promoter.syncFile(tempFile);
        for (final checkpoint in [checkpointFile, checkpointBackupFile]) {
          if (await checkpoint.exists()) await promoter.syncFile(checkpoint);
        }
      }
      if (capabilities.directorySync) {
        await promoter.syncDirectory(destinationDir);
      }
      state.transition(TransferState.promoting);
      await onProbe?.call(
          TransferProbe(TransferProbeStage.promotionStarted, copiedBytes));
      await beforePromotion?.call();
      await promoter.promoteNoReplace(tempFile, finalFile);
      try {
        await onProbe
            ?.call(TransferProbe(TransferProbeStage.promoted, copiedBytes));
        await afterPromotion?.call();
        if (capabilities.directorySync) {
          await promoter.syncDirectory(destinationDir);
        }
        final finalVerificationTimer = Stopwatch()..start();
        if (await FileSystemEntity.type(finalFile.path, followLinks: false) !=
                FileSystemEntityType.file ||
            await finalFile.length() != totalBytes ||
            (await sha256.bind(finalFile.openRead()).single).toString() !=
                sourceDigest ||
            await source.length() != totalBytes ||
            (await sha256.bind(source.openRead()).single).toString() !=
                sourceDigest) {
          throw PromotionException(
              PromotionFailure.verification,
              'Promoted file failed final verification; retained for recovery',
              finalFile.path,
              destinationMayExist: true);
        }
        metrics.finalVerificationMicros =
            finalVerificationTimer.elapsedMicroseconds;
        await onProbe?.call(
            TransferProbe(TransferProbeStage.finalVerified, copiedBytes));
      } catch (error) {
        // Never rename/delete this path: another writer could now own it.
        if (error is PromotionException && error.destinationMayExist) rethrow;
        throw PromotionException(
            error is PromotionException ? error.kind : PromotionFailure.io,
            'Post-promotion failure; retained for recovery: $error',
            finalFile.path,
            destinationMayExist: true);
      }
      state.transition(TransferState.committed);
      for (final file in [
        checkpointFile,
        checkpointBackupFile,
        checkpointStagingFile,
      ]) {
        try {
          if (await file.exists()) await file.delete();
        } on FileSystemException {
          // Promotion is already complete and verified. A leftover checkpoint
          // is harmless and must not turn a successful copy into a failed one.
        }
      }
      timer.stop();
      final seconds = timer.elapsedMicroseconds / 1e6;
      return FileAuditResult(
        fileName: fileName,
        destinationFileName: finalFile.uri.pathSegments.last,
        byteSize: totalBytes,
        sha256Hash: sourceDigest,
        mediaStatus: status,
        byteForByteVerified: true,
        transferMbps:
            seconds > 0 ? (totalBytes - resumedBytes) / 1048576 / seconds : 0,
        resumedBytes: resumedBytes,
        transferredBytes: totalBytes - resumedBytes,
        storageCommitEvidence: StorageCommitEvidence(capabilities,
            fileSyncCompleted: capabilities.nativeFileSync,
            directorySyncCompleted: capabilities.directorySync),
      );
    } catch (error) {
      if (state.state != TransferState.committed &&
          state.state != TransferState.failed &&
          state.state != TransferState.cancelled) {
        state.transition(error is TransferCancelledException
            ? TransferState.cancelled
            : TransferState.failed);
      }
      if (output != null) {
        try {
          await output.close();
        } catch (_) {}
      }
      if (discardPartial && pathsReady) {
        try {
          if (await tempFile.exists()) await tempFile.delete();
          for (final checkpoint in [
            checkpointFile,
            checkpointBackupFile,
            checkpointStagingFile,
          ]) {
            if (await checkpoint.exists()) await checkpoint.delete();
          }
        } on FileSystemException {
          // Preserve the original verification failure.
        }
      }
      rethrow;
    } finally {
      await workspaceLease?.release();
    }
  }

  static Future<FileAuditResult?> _reuseExistingCopy({
    required File source,
    required File candidate,
    required String fileName,
    required int totalBytes,
    required String sourceDigest,
  }) async {
    final existingBytes = await candidate.length();
    final existingDigest =
        (await sha256.bind(candidate.openRead()).single).toString();
    if (existingBytes != totalBytes || existingDigest != sourceDigest) {
      return null;
    }

    final currentSourceDigest =
        (await sha256.bind(source.openRead()).single).toString();
    if (currentSourceDigest != sourceDigest ||
        await source.length() != totalBytes) {
      throw FileSystemException(
        'Source changed while verifying an existing copy',
        source.path,
      );
    }
    final status = await inspectMediaHeader(candidate, mediaName: fileName);
    if (status == MediaIntegrityStatus.ioError) {
      throw FileSystemException('Media inspection failed', candidate.path);
    }
    return FileAuditResult(
      fileName: fileName,
      destinationFileName: candidate.uri.pathSegments.last,
      byteSize: totalBytes,
      sha256Hash: sourceDigest,
      mediaStatus: status,
      byteForByteVerified: true,
      transferMbps: 0,
      reusedExistingCopy: true,
    );
  }

  static Stream<List<int>> _verificationStream(
      File file, FutureOr<void> Function(TransferProbe)? onProbe) async* {
    var read = 0;
    await for (final chunk in file.openRead()) {
      read += chunk.length;
      await onProbe
          ?.call(TransferProbe(TransferProbeStage.verificationBlockRead, read));
      yield chunk;
    }
  }

  static String _fileNameWithCopyNumber(String fileName, int copyNumber) {
    final extensionStart = fileName.lastIndexOf('.');
    final splitAt = extensionStart > 0 ? extensionStart : fileName.length;
    final name = fileName.substring(0, splitAt);
    final extension = fileName.substring(splitAt);
    return '$name ($copyNumber)$extension';
  }

  static Future<void> _validateDestination(
      Directory root, Directory destination) async {
    String normalize(String path) {
      final value = Uri.file(path, windows: Platform.isWindows)
          .normalizePath()
          .toFilePath(windows: Platform.isWindows);
      return Platform.isWindows ? value.toLowerCase() : value;
    }

    bool within(String base, String path) =>
        path == base || path.startsWith('$base${Platform.pathSeparator}');

    final rootPath = normalize(root.absolute.path);
    final destinationPath = normalize(destination.absolute.path);
    if (!within(rootPath, destinationPath)) {
      throw FileSystemException(
          'Destination escapes the selected root', destination.path);
    }
    if (!await root.exists()) return;
    final realRoot = normalize(await root.resolveSymbolicLinks());
    var current = root.absolute.path;
    final relative = destinationPath.substring(rootPath.length);
    for (final component in relative.split(Platform.pathSeparator)) {
      if (component.isEmpty) continue;
      current = '$current${Platform.pathSeparator}$component';
      final directory = Directory(current);
      if (!await directory.exists()) break;
      final resolved = normalize(await directory.resolveSymbolicLinks());
      if (!within(realRoot, resolved)) {
        throw FileSystemException(
            'Destination symlink escapes the selected root', directory.path);
      }
    }
  }

  static Future<Map<String, dynamic>?> _readCheckpoint(File file) async {
    try {
      final checkpoint =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final version = checkpoint['version'];
      if (version == 2) {
        final metadataSha256 = checkpoint['metadataSha256'];
        final metadata = Map<String, dynamic>.from(checkpoint)
          ..remove('metadataSha256');
        if (metadataSha256 is! String ||
            sha256.convert(utf8.encode(jsonEncode(metadata))).toString() !=
                metadataSha256) {
          return null;
        }
        if (checkpoint['generation'] is! int ||
            (checkpoint['generation'] as int) <= 0) {
          return null;
        }
      } else if (version == 1) {
        // Read checkpoints from the previous release; the next saved block
        // upgrades the journal to the checksummed two-generation format.
        checkpoint['generation'] = 0;
      } else {
        return null;
      }

      if (checkpoint['sourcePath'] is! String ||
          checkpoint['sourceBytes'] is! int ||
          checkpoint['sourceSha256'] is! String ||
          checkpoint['blockBytes'] is! int ||
          checkpoint['offset'] is! int ||
          checkpoint['blockSha256'] is! List ||
          (checkpoint['blockSha256'] as List).any((hash) =>
              hash is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash))) {
        return null;
      }
      return checkpoint;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  /// Stages and flushes a checksummed snapshot before rotating the previous
  /// valid generation to a backup. The backup remains available until the next
  /// checkpoint or successful promotion, so a torn update can resume safely.
  static Future<int> _writeCheckpoint({
    required File checkpointFile,
    required File backupFile,
    required File stagingFile,
    required Map<String, Object?> checkpoint,
  }) async {
    final metadataSha256 =
        sha256.convert(utf8.encode(jsonEncode(checkpoint))).toString();
    final encoded =
        jsonEncode({...checkpoint, 'metadataSha256': metadataSha256});
    await stagingFile.writeAsString(
      encoded,
      flush: true,
    );

    if (await checkpointFile.exists()) {
      if (await backupFile.exists()) await backupFile.delete();
      await checkpointFile.rename(backupFile.path);
    }
    await stagingFile.rename(checkpointFile.path);
    return utf8.encode(encoded).length;
  }

  static int _uint32(List<int> bytes, int start) =>
      (bytes[start] << 24) |
      (bytes[start + 1] << 16) |
      (bytes[start + 2] << 8) |
      bytes[start + 3];
}
