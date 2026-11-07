import 'dart:io';
import 'dart:typed_data';

class MediaIntelligenceTag {
  final String fileName;
  final String
      category; // e.g., '4K Cinema / Video', 'RAW / High-Res Photo', 'Burst Candidate'
  final int structuralHash64;
  final String? similarToFile;
  final int hammingDistance;

  const MediaIntelligenceTag({
    required this.fileName,
    required this.category,
    required this.structuralHash64,
    this.similarToFile,
    this.hammingDistance = 64,
  });
}

class OfflineMediaIntelligence {
  /// Computes a fast 64-bit structural gradient fingerprint (dHash-style) over sampled payload bytes.
  /// Works deterministically on any image/media buffer without external native dependencies.
  static Future<int> computeStructuralFingerprint(File file) async {
    final length = await file.length();
    if (length == 0) return 0;

    final raf = await file.open(mode: FileMode.read);
    try {
      // Sample 72 evenly spaced bytes across the payload to build 64 adjacent gradient comparisons
      final samples = Uint8List(72);
      final step = length > 72 ? (length ~/ 72) : 1;

      for (int i = 0; i < 72; i++) {
        final pos = (i * step).clamp(0, length - 1).toInt();
        await raf.setPosition(pos);
        final byteRead = await raf.read(1);
        samples[i] = byteRead.isNotEmpty ? byteRead[0] : 0;
      }

      int hash = 0;
      for (int bit = 0; bit < 64; bit++) {
        if (samples[bit] > samples[bit + 1]) {
          hash |= (1 << bit);
        }
      }
      return hash;
    } finally {
      await raf.close();
    }
  }

  /// Calculates Hamming distance between two 64-bit fingerprints (<= 6 indicates near-duplicate burst).
  static int hammingDistance64(int a, int b) {
    int xor = a ^ b;
    int count = 0;
    while (xor != 0) {
      xor &= (xor - 1);
      count++;
    }
    return count;
  }

  /// Classifies files and links near-duplicate burst shots 100% offline.
  static Future<List<MediaIntelligenceTag>> analyzeDirectory(
    List<File> files, {
    Set<String> skipSimilarMatchNames = const {},
  }) async {
    final tags = <MediaIntelligenceTag>[];
    final seenFingerprints = <String, int>{};

    for (final file in files) {
      final name = file.uri.pathSegments.last;
      final lower = name.toLowerCase();
      final fp = await computeStructuralFingerprint(file);

      String category = 'General Media';
      if (lower.endsWith('.mp4') || lower.endsWith('.mov')) {
        category = '4K Video Asset';
      } else if (lower.endsWith('.raw') ||
          lower.endsWith('.arw') ||
          lower.endsWith('.dng')) {
        category = 'Uncompressed RAW';
      } else if (lower.endsWith('.jpg') ||
          lower.endsWith('.jpeg') ||
          lower.endsWith('.heic')) {
        category = 'Photo Asset';
      }

      String? closestMatch;
      int bestDist = 64;

      if (!skipSimilarMatchNames.contains(name)) {
        for (final entry in seenFingerprints.entries) {
          final dist = hammingDistance64(fp, entry.value);
          if (dist < bestDist) {
            bestDist = dist;
            closestMatch = entry.key;
          }
        }
        seenFingerprints[name] = fp;
      }

      tags.add(
        MediaIntelligenceTag(
          fileName: name,
          category: bestDist <= 6 ? 'Structural Match Candidate' : category,
          structuralHash64: fp,
          similarToFile: bestDist <= 6 ? closestMatch : null,
          hammingDistance: bestDist,
        ),
      );
    }

    return tags;
  }
}
