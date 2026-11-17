import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flashguard_ai/core/integrity_engine.dart';
import 'package:flashguard_ai/core/transfer_state_machine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Lifecycle accepts the verified path and rejects terminal resurrection',
      () {
    final state = TransferStateMachine();
    for (final next in [
      TransferState.hashingSource,
      TransferState.copying,
      TransferState.checkpointed,
      TransferState.paused,
      TransferState.copying,
      TransferState.verifying,
      TransferState.promoting,
      TransferState.committed,
    ]) {
      state.transition(next);
    }
    expect(state.state, TransferState.committed);
    expect(() => state.transition(TransferState.copying), throwsStateError);
    final failed = TransferStateMachine()
      ..transition(TransferState.hashingSource)
      ..transition(TransferState.failed);
    expect(() => failed.transition(TransferState.committed), throwsStateError);
    final cancelled = TransferStateMachine()
      ..transition(TransferState.cancelled);
    expect(
        () => cancelled.transition(TransferState.committed), throwsStateError);
  });

  test('Destination cannot escape its root', () async {
    final workspace = await Directory.systemTemp.createTemp('fg_guard_');
    try {
      final source = File('${workspace.path}/source.bin')
        ..writeAsBytesSync([1, 2, 3]);
      final root = await Directory('${workspace.path}/vault').create();
      final escaped = Directory('${root.path}/../escaped');
      final state = TransferStateMachine();
      await expectLater(
        IntegrityEngine.verifiedOffload(
          source: source,
          destinationDir: escaped,
          destinationRoot: root,
          lifecycle: state,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(state.state, TransferState.failed);
      expect(await escaped.exists(), isFalse);
    } finally {
      await workspace.delete(recursive: true);
    }
  });

  test('Promotion conflict is explicit and preserves the existing file',
      () async {
    final workspace = await Directory.systemTemp.createTemp('fg_conflict_');
    try {
      final source = File('${workspace.path}/source.bin');
      await source.writeAsBytes([1, 2, 3, 4]);
      final vault = await Directory('${workspace.path}/vault').create();
      final target = File('${vault.path}/source.bin');
      final state = TransferStateMachine();
      await expectLater(
        IntegrityEngine.verifiedOffload(
          source: source,
          destinationDir: vault,
          lifecycle: state,
          checkpointBlockBytes: 2,
          beforePromotion: () => target.writeAsBytes([9, 9, 9]),
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await target.readAsBytes(), [9, 9, 9]);
      expect(state.state, TransferState.failed);
      expect(state.history.map((step) => step.to),
          contains(TransferState.promoting));
    } finally {
      await workspace.delete(recursive: true);
    }
  });

  test('100 seeded interruption and recovery scenarios preserve invariants',
      () async {
    const firstSeed = 0x5a1700;
    for (var index = 0; index < 100; index++) {
      final seed = firstSeed + index;
      final random = Random(seed);
      final workspace = await Directory.systemTemp.createTemp('fg_prop_$seed');
      final states = <TransferStateMachine>[];
      final size = index == 0 ? 0 : random.nextInt(300);
      final block = 16 + random.nextInt(112);
      final interruptions = size == 0 ? 0 : random.nextInt(3);
      final nested = random.nextBool();
      final conflict = random.nextBool();
      final corruptPart = random.nextBool();
      final corruptJournals = random.nextBool();
      final mutateSource = random.nextBool();
      final parameters = 'seed=$seed size=$size block=$block '
          'interruptions=$interruptions nested=$nested conflict=$conflict '
          'corruptPart=$corruptPart corruptJournals=$corruptJournals '
          'mutateSource=$mutateSource';
      try {
        final sourceDir = await Directory('${workspace.path}/source').create();
        final root = await Directory('${workspace.path}/vault').create();
        final data = List<int>.generate(size, (_) => random.nextInt(256));
        final source = File('${sourceDir.path}/case.bin');
        await source.writeAsBytes(data);
        final originalDigest = sha256.convert(data).toString();
        final destination = nested
            ? await Directory('${root.path}/nested/deeper')
                .create(recursive: true)
            : root;
        final primary = File('${destination.path}/case.bin');
        if (conflict) await primary.writeAsBytes([0xde, 0xad, 0xbe, 0xef]);
        final name = conflict ? 'case (2).bin' : 'case.bin';
        final finalFile = File('${destination.path}/$name');
        final part = File('${finalFile.path}.part');
        final journal = File('${finalFile.path}.checkpoint.json');
        for (var attempt = 0; attempt < interruptions; attempt++) {
          final state = TransferStateMachine();
          states.add(state);
          final stopAt = 1 + random.nextInt(size);
          await expectLater(
            IntegrityEngine.verifiedOffload(
              source: source,
              destinationDir: destination,
              destinationRoot: root,
              lifecycle: state,
              expectedSha256: originalDigest,
              checkpointBlockBytes: block,
              onProgress: (fraction) {
                if ((fraction * size).round() >= stopAt) {
                  throw FileSystemException('Seeded interruption', source.path);
                }
              },
            ),
            throwsA(isA<FileSystemException>()),
          );
          expect(state.state, TransferState.failed);
          expect(await finalFile.exists(), isFalse);
          var completeCheckpoint = false;
          if (await journal.exists()) {
            final snapshot = jsonDecode(await journal.readAsString()) as Map;
            expect(snapshot['offset'] as int, inInclusiveRange(0, size));
            completeCheckpoint = snapshot['offset'] == size;
          }
          if (corruptPart && await part.exists() && await part.length() > 0) {
            final handle = await part.open(mode: FileMode.writeOnly);
            try {
              await handle.setPosition(0);
              await handle.writeByte(0x7f);
            } finally {
              await handle.close();
            }
          }
          if (corruptJournals) {
            await journal.writeAsString('{invalid');
            await File('${journal.path}.bak').writeAsString('{invalid');
          }
          // A full checkpoint can legitimately verify and promote on retry.
          if (completeCheckpoint) break;
        }
        if (mutateSource && interruptions > 0) {
          await source.writeAsBytes([...data, 0xaa]);
          final state = TransferStateMachine();
          states.add(state);
          await expectLater(
            IntegrityEngine.verifiedOffload(
              source: source,
              destinationDir: destination,
              destinationRoot: root,
              lifecycle: state,
              expectedSha256: originalDigest,
              checkpointBlockBytes: block,
            ),
            throwsA(isA<FileSystemException>()),
          );
          expect(state.state, TransferState.failed);
          expect(await finalFile.exists(), isFalse);
          await source.writeAsBytes(data);
        }
        final state = TransferStateMachine();
        states.add(state);
        final result = await IntegrityEngine.verifiedOffload(
          source: source,
          destinationDir: destination,
          destinationRoot: root,
          lifecycle: state,
          expectedSha256: originalDigest,
          checkpointBlockBytes: block,
        );
        expect(state.state, TransferState.committed);
        expect(result.byteForByteVerified, isTrue);
        expect(result.sha256Hash, originalDigest);
        expect(sha256.convert(await finalFile.readAsBytes()).toString(),
            originalDigest);
        expect(await source.readAsBytes(), data);
        if (conflict) {
          expect(await primary.readAsBytes(), [0xde, 0xad, 0xbe, 0xef]);
        }
        expect(await part.exists(), isFalse);
      } catch (error, stack) {
        fail('$parameters\n$error\n$stack\nTransitions: '
            '${states.map((state) => state.history.join(', ')).join(' | ')}');
      } finally {
        await workspace.delete(recursive: true);
      }
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
