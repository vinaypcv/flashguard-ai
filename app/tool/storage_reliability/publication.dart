import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Redact location strings only. Counters, timings, seeds and hashes remain raw.
Future<Map<String, Object?>> publicationCopy(
    Map<String, Object?> artifact, String runRoot) async {
  final original = '${const JsonEncoder.withIndent('  ').convert(artifact)}\n';
  final repo = Directory.current.path;
  final replacements = <String, String>{
    runRoot: '<RUN_WORKSPACE>',
    runRoot.replaceAll('\\', '/'): '<RUN_WORKSPACE>',
    repo: '<WORKSPACE>',
    repo.replaceAll('\\', '/'): '<WORKSPACE>'
  };
  Object? redact(Object? value) {
    if (value is String) {
      var result = value;
      for (final entry in replacements.entries) {
        result = result.replaceAll(entry.key, entry.value);
      }
      return result;
    }
    if (value is List) return value.map(redact).toList();
    if (value is Map) {
      return {
        for (final entry in value.entries)
          entry.key.toString(): redact(entry.value)
      };
    }
    return value;
  }

  final published = (redact(artifact) as Map).cast<String, Object?>();
  published['pathRedactions'] = {
    'appliedBeforePublication': true,
    'description':
        'Repository and temporary-root strings replaced; measurements unchanged.',
    'originalArtifactSha256': sha256.convert(utf8.encode(original)).toString()
  };
  return published;
}
