import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flashguard_ai/core/atomic_file_promoter.dart';
import 'package:flashguard_ai/core/integrity_engine.dart';
import 'package:flashguard_ai/core/transfer_state_machine.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakePromoter implements AtomicFilePromoter {
  final bool supported;
  final bool failSync;
  final bool failAfterMove;
  final bool failFinalDirectorySync;
  final List<String> calls = [];
  @override
  Future<TransferWorkspaceLease> acquireWorkspace(File destination) =>
      const NativeAtomicFilePromoter().acquireWorkspace(destination);
  _FakePromoter(
      {this.supported = true,
      this.failSync = false,
      this.failAfterMove = false,
      this.failFinalDirectorySync = false});
  @override
  Future<PromotionCapabilities> capabilities(Directory directory) async =>
      PromotionCapabilities(
          atomicNoReplace: supported,
          nativeFileSync: true,
          directorySync: true,
          description: 'Deterministic test capability');
  @override
  Future<void> syncFile(File file) async {
    calls.add('sync:${file.uri.pathSegments.last}');
    if (failSync) {
      throw PromotionException(
          PromotionFailure.io, 'Injected sync failure', file.path);
    }
  }

  @override
  Future<void> syncDirectory(Directory directory) async {
    calls.add('directory');
    if (failFinalDirectorySync &&
        calls.where((call) => call == 'directory').length == 2) {
      throw PromotionException(
          PromotionFailure.io, 'Injected parent sync failure', directory.path);
    }
  }

  @override
  Future<void> promoteNoReplace(File temporary, File destination) async {
    calls.add('promote');
    if (failAfterMove || failFinalDirectorySync) {
      await const NativeAtomicFilePromoter()
          .promoteNoReplace(temporary, destination);
      if (!failAfterMove) return;
      throw PromotionException(PromotionFailure.io,
          'Injected loss after native move', destination.path,
          destinationMayExist: true);
    }
    throw PromotionException(
        PromotionFailure.io, 'Injected promotion failure', destination.path);
  }
}

void main() {
  late Directory root;
  late Directory vault;
  late File source;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('fg_promotion_');
    vault = await Directory('${root.path}/vault').create();
    source = File('${root.path}/source.bin');
    await source.writeAsBytes(List.generate(96, (i) => i));
  });
  tearDown(() async => root.delete(recursive: true));

  test('Unsupported capability fails closed before writing a part', () async {
    final fake = _FakePromoter(supported: false);
    final state = TransferStateMachine();
    await expectLater(
        IntegrityEngine.verifiedOffload(
            source: source,
            destinationDir: vault,
            promoter: fake,
            lifecycle: state),
        throwsA(isA<PromotionException>()
            .having((e) => e.kind, 'kind', PromotionFailure.unsupported)));
    expect(state.state, TransferState.failed);
    expect(fake.calls, isEmpty);
    expect(await vault.list().toList(), isEmpty);
  });

  test(
      'Verified part survives promotion failure and journal is revalidated on retry',
      () async {
    final fake = _FakePromoter();
    final state = TransferStateMachine();
    await expectLater(
        IntegrityEngine.verifiedOffload(
            source: source,
            destinationDir: vault,
            promoter: fake,
            lifecycle: state,
            checkpointBlockBytes: 32),
        throwsA(isA<PromotionException>()));
    expect(state.state, TransferState.failed);
    expect(fake.calls, [
      'sync:source.bin.part',
      'sync:source.bin.checkpoint.json',
      'sync:source.bin.checkpoint.json.bak',
      'directory',
      'promote'
    ]);
    final part = File('${vault.path}/source.bin.part');
    expect(sha256.convert(await part.readAsBytes()),
        sha256.convert(await source.readAsBytes()));
    // Metadata is damaged after the failed promotion: recovery must restart.
    await File('${vault.path}/source.bin.checkpoint.json')
        .writeAsString('{torn');
    await File('${vault.path}/source.bin.checkpoint.json.bak')
        .writeAsString('{torn');
    final result = await IntegrityEngine.verifiedOffload(
        source: source, destinationDir: vault, checkpointBlockBytes: 32);
    expect(result.resumedBytes, 0);
    expect(result.byteForByteVerified, isTrue);
  });

  test('Native sync failure prevents promotion', () async {
    final fake = _FakePromoter(failSync: true);
    await expectLater(
        IntegrityEngine.verifiedOffload(
            source: source, destinationDir: vault, promoter: fake),
        throwsA(isA<PromotionException>()));
    expect(fake.calls, ['sync:source.bin.part']);
    expect(await File('${vault.path}/source.bin').exists(), isFalse);
  });

  test('Late competing writer is preserved and retry chooses a numbered name',
      () async {
    final target = File('${vault.path}/source.bin');
    await expectLater(
        IntegrityEngine.verifiedOffload(
            source: source,
            destinationDir: vault,
            beforePromotion: () => target.writeAsString('competitor')),
        throwsA(isA<PromotionException>()
            .having((e) => e.kind, 'kind', PromotionFailure.conflict)));
    expect(await target.readAsString(), 'competitor');
    final result = await IntegrityEngine.verifiedOffload(
        source: source, destinationDir: vault);
    expect(result.destinationFileName, 'source (2).bin');
    expect(await target.readAsString(), 'competitor');
  });

  test('Incomplete promotion is recovered by rehashing the already moved final',
      () async {
    final state = TransferStateMachine();
    await expectLater(
        IntegrityEngine.verifiedOffload(
            source: source,
            destinationDir: vault,
            promoter: _FakePromoter(failAfterMove: true),
            lifecycle: state),
        throwsA(isA<PromotionException>()
            .having((e) => e.destinationMayExist, 'retained', isTrue)));
    expect(state.state, TransferState.failed);
    expect(await File('${vault.path}/source.bin.checkpoint.json').exists(),
        isTrue);
    final result = await IntegrityEngine.verifiedOffload(
        source: source, destinationDir: vault);
    expect(result.reusedExistingCopy, isTrue);
    expect(result.byteForByteVerified, isTrue);
    expect(result.storageCommitEvidence,
        isNull); // Reuse makes no fresh sync claim.
  });

  test(
      'Post-promotion damage is retained unverified without deleting a replacement',
      () async {
    final target = File('${vault.path}/source.bin');
    final state = TransferStateMachine();
    await expectLater(
        IntegrityEngine.verifiedOffload(
            source: source,
            destinationDir: vault,
            lifecycle: state,
            afterPromotion: () =>
                target.writeAsString('replacement from another writer')),
        throwsA(isA<PromotionException>()
            .having((e) => e.kind, 'kind', PromotionFailure.verification)
            .having((e) => e.destinationMayExist, 'retained', isTrue)));
    expect(state.state, TransferState.failed);
    expect(await target.readAsString(), 'replacement from another writer');
    final result = await IntegrityEngine.verifiedOffload(
        source: source, destinationDir: vault);
    expect(result.destinationFileName, 'source (2).bin');
    expect(await target.readAsString(), 'replacement from another writer');
    expect(await source.length(), 96);
  });

  test(
      'Successful commit reports completed native requests without claiming crash durability',
      () async {
    final result = await IntegrityEngine.verifiedOffload(
        source: source, destinationDir: vault);
    expect(result.storageCommitEvidence!.fileSyncCompleted, isTrue);
    expect(
        result.storageCommitEvidence!.directorySyncCompleted, Platform.isLinux);
    expect(result.withRelativePath('nested/source.bin').storageCommitEvidence,
        result.storageCommitEvidence);
  });

  test('Concurrent engine jobs cannot share mutable recovery sidecars',
      () async {
    final reached = Completer<void>();
    final resume = Completer<void>();
    final first = IntegrityEngine.verifiedOffload(
        source: source,
        destinationDir: vault,
        checkpointBlockBytes: 32,
        onProgress: (_) async {
          if (!reached.isCompleted) {
            reached.complete();
            await resume.future;
          }
        });
    try {
      await reached.future;
      await expectLater(
          IntegrityEngine.verifiedOffload(
              source: source, destinationDir: vault, checkpointBlockBytes: 32),
          throwsA(isA<PromotionException>()));
    } finally {
      resume.complete();
    }
    final result = await first;
    expect(result.byteForByteVerified, isTrue);
    expect(await File('${vault.path}/source.bin').readAsBytes(),
        await source.readAsBytes());
  });

  test('Failure to sync parent after promotion never reports committed',
      () async {
    final state = TransferStateMachine();
    final fake = _FakePromoter(failFinalDirectorySync: true);
    await expectLater(
        IntegrityEngine.verifiedOffload(
            source: source,
            destinationDir: vault,
            lifecycle: state,
            promoter: fake),
        throwsA(isA<PromotionException>()
            .having((e) => e.destinationMayExist, 'retained', isTrue)));
    expect(state.state, TransferState.failed);
    expect(fake.calls, [
      'sync:source.bin.part',
      'sync:source.bin.checkpoint.json',
      'directory',
      'promote',
      'directory'
    ]);
    expect(await File('${vault.path}/source.bin.checkpoint.json').exists(),
        isTrue);
    final result = await IntegrityEngine.verifiedOffload(
        source: source, destinationDir: vault);
    expect(result.reusedExistingCopy, isTrue);
  });
}
