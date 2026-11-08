import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';

enum MediaIntegrityStatus {
  valid,
  corruptedHeader,
  truncatedContainer,
  ioError,
}

class FileAuditResult {
  final String fileName;
  final int byteSize;
  final String sha256Hash;
  final MediaIntegrityStatus status;
  final double transferMbps;
  final int resumedBytes;
  final int transferredBytes;
  final bool reusedExistingCopy;

  const FileAuditResult({
    required this.fileName,
    required this.byteSize,
    required this.sha256Hash,
    required this.status,
    required this.transferMbps,
    this.resumedBytes = 0,
    this.transferredBytes = 0,
    this.reusedExistingCopy = false,
  });

  bool get isCopyVerified => status == MediaIntegrityStatus.valid;

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
    void Function(double progress)? onProgress,
    String? expectedSha256,
    int checkpointBlockBytes = 4 * 1024 * 1024,
  }) async {
    if (checkpointBlockBytes <= 0) {
      throw ArgumentError.value(checkpointBlockBytes, 'checkpointBlockBytes');
    }
    final timer = Stopwatch()..start();
    final fileName = source.uri.pathSegments.last;
    final finalFile =
        File('${destinationDir.path}${Platform.pathSeparator}$fileName');
    final tempFile = File('${finalFile.path}.part');
    final checkpointFile = File('${finalFile.path}.checkpoint.json');
    RandomAccessFile? output;
    var discardPartial = false;
    try {
      if (!await destinationDir.exists()) {
        await destinationDir.create(recursive: true);
      }
      final totalBytes = await source.length();
      final sourceDigest =
          (await sha256.bind(source.openRead()).single).toString();
      if (expectedSha256 != null &&
          sourceDigest != expectedSha256.toLowerCase()) {
        throw FileSystemException(
            'Source SHA-256 differs from trusted digest', source.path);
      }

      if (await finalFile.exists()) {
        final existingBytes = await finalFile.length();
        final existingDigest =
            (await sha256.bind(finalFile.openRead()).single).toString();
        final currentSourceDigest =
            (await sha256.bind(source.openRead()).single).toString();
        if (existingBytes != totalBytes ||
            existingDigest != sourceDigest ||
            currentSourceDigest != sourceDigest ||
            await source.length() != totalBytes) {
          throw FileSystemException(
            'Destination already exists with different contents',
            finalFile.path,
          );
        }
        final status = await inspectMediaHeader(finalFile, mediaName: fileName);
        if (status == MediaIntegrityStatus.ioError) {
          throw FileSystemException('Media inspection failed', finalFile.path);
        }
        return FileAuditResult(
          fileName: fileName,
          byteSize: totalBytes,
          sha256Hash: sourceDigest,
          status: status,
          transferMbps: 0,
          reusedExistingCopy: true,
        );
      }

      var resumedBytes = 0;
      var blockHashes = <String>[];
      if (await tempFile.exists() && await checkpointFile.exists()) {
        try {
          final checkpoint = jsonDecode(await checkpointFile.readAsString())
              as Map<String, dynamic>;
          final savedHashes =
              (checkpoint['blockSha256'] as List).cast<String>();
          final offset = checkpoint['offset'] as int;
          if (checkpoint['version'] != 1 ||
              checkpoint['sourcePath'] != source.absolute.path ||
              checkpoint['sourceBytes'] != totalBytes ||
              checkpoint['sourceSha256'] != sourceDigest ||
              checkpoint['blockBytes'] != checkpointBlockBytes ||
              offset < 0 ||
              offset > totalBytes ||
              savedHashes.length != (offset / checkpointBlockBytes).ceil() ||
              await tempFile.length() < offset) {
            throw const FormatException('Stale checkpoint');
          }
          final sourceReader = await source.open();
          final partReader = await tempFile.open();
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
                throw const FormatException('Checkpoint block mismatch');
              }
            }
          } finally {
            await sourceReader.close();
            await partReader.close();
          }
          resumedBytes = offset;
          blockHashes = savedHashes;
        } on FormatException {
          await tempFile.delete();
          await checkpointFile.delete();
        } on TypeError {
          await tempFile.delete();
          await checkpointFile.delete();
        }
      } else {
        if (await tempFile.exists()) await tempFile.delete();
        if (await checkpointFile.exists()) await checkpointFile.delete();
      }

      output = await tempFile.open(mode: FileMode.append);
      await output.truncate(resumedBytes);
      await output.setPosition(resumedBytes);
      final input = await source.open();
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
          blockHashes.add(sha256.convert(chunk).toString());
          copiedBytes += chunk.length;
          await checkpointFile.writeAsString(
              jsonEncode({
                'version': 1,
                'sourcePath': source.absolute.path,
                'sourceBytes': totalBytes,
                'sourceSha256': sourceDigest,
                'blockBytes': checkpointBlockBytes,
                'offset': copiedBytes,
                'blockSha256': blockHashes,
              }),
              flush: true);
          if (totalBytes > 0) onProgress?.call(copiedBytes / totalBytes);
        }
      } finally {
        await input.close();
      }
      await output.flush();
      await output.close();
      output = null;

      final destinationDigest =
          (await sha256.bind(tempFile.openRead()).single).toString();
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
      await tempFile.rename(finalFile.path);
      if (await checkpointFile.exists()) await checkpointFile.delete();
      timer.stop();
      final seconds = timer.elapsedMicroseconds / 1e6;
      return FileAuditResult(
        fileName: fileName,
        byteSize: totalBytes,
        sha256Hash: sourceDigest,
        status: status,
        transferMbps:
            seconds > 0 ? (totalBytes - resumedBytes) / 1048576 / seconds : 0,
        resumedBytes: resumedBytes,
        transferredBytes: totalBytes - resumedBytes,
      );
    } catch (_) {
      if (output != null) {
        try {
          await output.close();
        } catch (_) {}
      }
      if (discardPartial) {
        if (await tempFile.exists()) await tempFile.delete();
        if (await checkpointFile.exists()) await checkpointFile.delete();
      }
      rethrow;
    }
  }

  static int _uint32(List<int> bytes, int start) =>
      (bytes[start] << 24) |
      (bytes[start + 1] << 16) |
      (bytes[start + 2] << 8) |
      bytes[start + 3];
}
