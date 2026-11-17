import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'model.dart';

/// Each worker is a new OS process with its own VM and native handles.
class ProcessWorker {
  final Process process;
  final StreamIterator<String> events;
  final Future<String> errors;
  final Stopwatch timer;
  Map<String, dynamic>? lastEvent;
  bool _finished = false;
  ProcessWorker._(this.process, this.events, this.errors, this.timer);

  static Future<ProcessWorker> start(Map<String, Object?> config) async {
    final packages = await Isolate.packageConfig;
    final timer = Stopwatch()..start();
    final process = await Process.start(Platform.resolvedExecutable, [
      if (packages != null) '--packages=${packages.toFilePath()}',
      Platform.script.toFilePath(),
      '--worker'
    ]);
    final worker = ProcessWorker._(
        process,
        StreamIterator(process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())),
        process.stderr.transform(utf8.decoder).join(),
        timer);
    process.stdin.writeln(jsonEncode(config));
    return worker;
  }

  Future<Map<String, dynamic>> next() async {
    if (!await events.moveNext().timeout(const Duration(minutes: 2))) {
      throw StateError(
          'Worker ${process.pid} exited without event: ${await errors}');
    }
    lastEvent = jsonDecode(events.current) as Map<String, dynamic>;
    return lastEvent!;
  }

  Future<Map<String, dynamic>> ready() async {
    final event = await next();
    requireCondition(
        event['type'] == 'ready', 'Worker failed before gate: $event');
    return event;
  }

  void release() => process.stdin.writeln('continue');

  Future<Map<String, dynamic>> result() async {
    final event = await next();
    requireCondition(
        event['type'] == 'result', 'Expected worker result: $event');
    await process.stdin.close();
    final code = await process.exitCode.timeout(const Duration(minutes: 2));
    _finished = true;
    timer.stop();
    event['exitCode'] = code;
    event['controllerLatencyMicros'] = timer.elapsedMicroseconds;
    final stderrText = await errors;
    if (stderrText.isNotEmpty) event['stderr'] = stderrText;
    requireCondition((code == 0) == (event['status'] == 'passed'),
        'Worker exit/result disagreement: $event');
    await events.cancel();
    return event;
  }

  Future<int> kill() async {
    // SIGKILL on Linux; Dart uses native termination on Windows. No finally
    // blocks in the worker are relied on to close native workspace handles.
    requireCondition(process.kill(ProcessSignal.sigkill),
        'Failed to terminate ${process.pid}');
    final code = await process.exitCode.timeout(const Duration(seconds: 30));
    _finished = true;
    await events.cancel();
    await process.stdin.close().catchError((Object _) {});
    requireCondition(
        code != 0, 'Killed worker unexpectedly reported zero exit');
    return code;
  }

  Future<void> dispose() async {
    if (!_finished) {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      await events.cancel();
      await process.stdin.close().catchError((Object _) {});
    }
  }
}
