import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flashguard_ai/core/atomic_file_promoter.dart';
import 'package:flutter_test/flutter_test.dart';

// Separate isolates rendezvous before entering the actual native operation.
Future<void> _writer(List<Object> args) async {
  final events = args[0] as SendPort;
  final gate = ReceivePort();
  events.send(gate.sendPort);
  await gate.first;
  try {
    await const NativeAtomicFilePromoter()
        .promoteNoReplace(File(args[1] as String), File(args[2] as String));
    events.send('success');
  } on PromotionException catch (error) {
    events.send(error.kind == PromotionFailure.conflict
        ? error.kind.name
        : '${error.kind.name}:${error.osError?.errorCode}');
  } catch (error) {
    events.send(error.toString());
  } finally {
    gate.close();
  }
}

void main() {
  final nativePlatform = Platform.isWindows || Platform.isLinux;
  late Directory root;
  const promoter = NativeAtomicFilePromoter();
  setUp(() async => root = await Directory.systemTemp.createTemp('fg_native_'));
  tearDown(() async => root.delete(recursive: true));

  test('Native capabilities and file synchronization are observable', () async {
    final capabilities = await promoter.capabilities(root);
    expect(capabilities.atomicNoReplace, isTrue,
        reason: capabilities.description);
    expect(capabilities.nativeFileSync, isTrue);
    expect(capabilities.directorySync, Platform.isLinux);
    final part = File('${root.path}/unicode_\u03bb.part');
    await part.writeAsBytes([1, 2, 3], flush: true);
    await promoter.syncFile(part);
    if (capabilities.directorySync) await promoter.syncDirectory(root);
    final target = File('${root.path}/unicode_\u03bb.bin');
    await promoter.promoteNoReplace(part, target);
    expect(await part.exists(), isFalse);
    expect(await target.readAsBytes(), [1, 2, 3]);
  }, skip: !nativePlatform);

  test('Native concurrent writers have one winner and preserve both payloads',
      () async {
    for (var round = 0; round < 8; round++) {
      final a = File('${root.path}/a_$round.part');
      final b = File('${root.path}/b_$round.part');
      final target = File('${root.path}/final_$round.bin');
      await a.writeAsBytes([1, round, 1]);
      await b.writeAsBytes([2, round, 2]);
      final events = ReceivePort();
      final ready = <SendPort>[];
      final results = <String>[];
      final completed = Completer<void>();
      final subscription = events.listen((message) {
        if (message is SendPort) {
          ready.add(message);
          if (ready.length == 2) {
            for (final gate in ready) {
              gate.send('go');
            }
          }
        } else {
          results.add(message as String);
          if (results.length == 2) completed.complete();
        }
      });
      final isolates = <Isolate>[];
      try {
        isolates.add(await Isolate.spawn(
            _writer, <Object>[events.sendPort, a.path, target.path]));
        isolates.add(await Isolate.spawn(
            _writer, <Object>[events.sendPort, b.path, target.path]));
        await completed.future.timeout(const Duration(seconds: 30));
        expect(results, unorderedEquals(['success', 'conflict']),
            reason: 'round=$round');
        final winner = await target.readAsBytes();
        expect(winner, anyOf(equals([1, round, 1]), equals([2, round, 2])));
        final loser = winner.first == 1 ? b : a;
        expect(await loser.readAsBytes(),
            winner.first == 1 ? [2, round, 2] : [1, round, 1]);
        expect(await (winner.first == 1 ? a : b).exists(), isFalse);
      } finally {
        for (final isolate in isolates) {
          isolate.kill(priority: Isolate.immediate);
        }
        await subscription.cancel();
        events.close();
      }
    }
  }, skip: !nativePlatform);

  test(
      'Native operation preserves an existing target and rejects cross-directory promotion',
      () async {
    final part = File('${root.path}/part');
    final target = File('${root.path}/final');
    await part.writeAsString('new');
    await target.writeAsString('existing');
    await expectLater(
        promoter.promoteNoReplace(part, target),
        throwsA(isA<PromotionException>()
            .having((e) => e.kind, 'kind', PromotionFailure.conflict)));
    expect(await target.readAsString(), 'existing');
    expect(await part.readAsString(), 'new');
    final elsewhere = await Directory('${root.path}/elsewhere').create();
    await expectLater(
        promoter.promoteNoReplace(part, File('${elsewhere.path}/final')),
        throwsA(isA<PromotionException>()
            .having((e) => e.kind, 'kind', PromotionFailure.invalidPath)));
  }, skip: !nativePlatform);

  test('Native workspace lease excludes another owner and permits restart',
      () async {
    final target = File('${root.path}/lease.bin');
    final first = await promoter.acquireWorkspace(target);
    try {
      await expectLater(promoter.acquireWorkspace(target),
          throwsA(isA<PromotionException>()));
    } finally {
      await first.release();
    }
    final retry = await promoter.acquireWorkspace(target);
    await retry.release();
    expect(await File('${target.path}.transfer.lock').exists(), isTrue);
  }, skip: !nativePlatform);
}
