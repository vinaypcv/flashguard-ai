import 'dart:io';

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

  const FileAuditResult({
    required this.fileName,
    required this.byteSize,
    required this.sha256Hash,
    required this.status,
    required this.transferMbps,
  });

  bool get isCopyVerified => status == MediaIntegrityStatus.valid;
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

  /// Copies to a temporary file, hashes both volumes, then promotes the copy.
  static Future<FileAuditResult> verifiedOffload({
    required File source,
    required Directory destinationDir,
    void Function(double progress)? onProgress,
  }) async {
    final timer = Stopwatch()..start();
    final fileName = source.uri.pathSegments.last;
    final finalFile =
        File('${destinationDir.path}${Platform.pathSeparator}$fileName');
    final tempFile = File(
      '${finalFile.path}.${DateTime.now().microsecondsSinceEpoch}.part',
    );
    IOSink? output;
    try {
      if (!await destinationDir.exists()) {
        await destinationDir.create(recursive: true);
      }
      if (await finalFile.exists()) {
        throw FileSystemException('Destination already exists', finalFile.path);
      }
      final totalBytes = await source.length();
      output = tempFile.openWrite();
      var copiedBytes = 0;
      final sourceDigest = await sha256
          .bind(
            source.openRead().map((chunk) {
              output!.add(chunk);
              copiedBytes += chunk.length;
              if (totalBytes > 0) onProgress?.call(copiedBytes / totalBytes);
              return chunk;
            }),
          )
          .single;
      await output.flush();
      await output.close();
      output = null;

      final destinationDigest = await sha256.bind(tempFile.openRead()).single;
      final currentSourceDigest = await sha256.bind(source.openRead()).single;
      if (copiedBytes != totalBytes ||
          await source.length() != totalBytes ||
          destinationDigest != sourceDigest ||
          currentSourceDigest != sourceDigest) {
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
      timer.stop();
      final seconds = timer.elapsedMicroseconds / 1e6;
      return FileAuditResult(
        fileName: fileName,
        byteSize: totalBytes,
        sha256Hash: sourceDigest.toString(),
        status: status,
        transferMbps: seconds > 0 ? totalBytes / 1048576 / seconds : 0,
      );
    } catch (_) {
      if (output != null) {
        try {
          await output.close();
        } catch (_) {}
      }
      if (await tempFile.exists()) await tempFile.delete();
      rethrow;
    }
  }

  static int _uint32(List<int> bytes, int start) =>
      (bytes[start] << 24) |
      (bytes[start + 1] << 16) |
      (bytes[start + 2] << 8) |
      bytes[start + 3];
}
