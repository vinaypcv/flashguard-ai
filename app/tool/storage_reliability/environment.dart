import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

class VolumeInfo {
  final String mount;
  final String source;
  final String fileSystem;
  final String label;
  final int totalBytes;
  final int freeBytes;
  const VolumeInfo(this.mount, this.source, this.fileSystem, this.label,
      this.totalBytes, this.freeBytes);
  Map<String, Object> toJson() => {
        'mount': mount,
        'source': source,
        'fileSystem': fileSystem,
        'label': label,
        'totalBytes': totalBytes,
        'freeBytes': freeBytes
      };
}

Future<VolumeInfo> inspectVolume(String path) async {
  if (Platform.isWindows) return Isolate.run(() => _windowsVolume(path));
  if (Platform.isLinux) {
    final result = await Process.run('df', ['-P', '-T', '-B1', path],
        environment: {'LC_ALL': 'C'});
    if (result.exitCode != 0) throw StateError('df failed: ${result.stderr}');
    final fields = (result.stdout as String)
        .trim()
        .split('\n')
        .last
        .trim()
        .split(RegExp(r'\s+'));
    return VolumeInfo(fields.sublist(6).join(' '), fields[0], fields[1], '',
        int.parse(fields[2]), int.parse(fields[4]));
  }
  throw UnsupportedError(
      'Volume inspection unavailable on ${Platform.operatingSystem}');
}

VolumeInfo _windowsVolume(String path) => using((arena) {
      final kernel = DynamicLibrary.open('kernel32.dll');
      final getPath = kernel.lookupFunction<
          Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
          int Function(
              Pointer<Utf16>, Pointer<Utf16>, int)>('GetVolumePathNameW');
      final getInfo = kernel.lookupFunction<
          Int32 Function(
              Pointer<Utf16>,
              Pointer<Utf16>,
              Uint32,
              Pointer<Uint32>,
              Pointer<Uint32>,
              Pointer<Uint32>,
              Pointer<Utf16>,
              Uint32),
          int Function(
              Pointer<Utf16>,
              Pointer<Utf16>,
              int,
              Pointer<Uint32>,
              Pointer<Uint32>,
              Pointer<Uint32>,
              Pointer<Utf16>,
              int)>('GetVolumeInformationW');
      final getSpace = kernel.lookupFunction<
          Int32 Function(Pointer<Utf16>, Pointer<Uint64>, Pointer<Uint64>,
              Pointer<Uint64>),
          int Function(Pointer<Utf16>, Pointer<Uint64>, Pointer<Uint64>,
              Pointer<Uint64>)>('GetDiskFreeSpaceExW');
      final mount = arena<Uint16>(32768).cast<Utf16>();
      final fs = arena<Uint16>(64).cast<Utf16>();
      final label = arena<Uint16>(256).cast<Utf16>();
      final serial = arena<Uint32>();
      final free = arena<Uint64>();
      final total = arena<Uint64>();
      if (getPath(path.replaceAll('/', r'\').toNativeUtf16(allocator: arena),
                  mount, 32768) ==
              0 ||
          getInfo(mount, label, 256, serial, nullptr, nullptr, fs, 64) == 0 ||
          getSpace(mount, free, total, nullptr) == 0) {
        throw StateError('Native volume query failed for $path');
      }
      return VolumeInfo(mount.toDartString(), '${serial.value}',
          fs.toDartString(), label.toDartString(), total.value, free.value);
    });

Future<int?> processCpuMicros() async {
  if (Platform.isWindows) {
    return Isolate.run(() => using((arena) {
          final fn = DynamicLibrary.open('kernel32.dll').lookupFunction<
              Int32 Function(IntPtr, Pointer<Uint64>, Pointer<Uint64>,
                  Pointer<Uint64>, Pointer<Uint64>),
              int Function(int, Pointer<Uint64>, Pointer<Uint64>,
                  Pointer<Uint64>, Pointer<Uint64>)>('GetProcessTimes');
          final creation = arena<Uint64>();
          final end = arena<Uint64>();
          final kernel = arena<Uint64>();
          final user = arena<Uint64>();
          return fn(-1, creation, end, kernel, user) == 0
              ? null
              : (kernel.value + user.value) ~/ 10;
        }));
  }
  if (Platform.isLinux) {
    final text = await File('/proc/self/stat').readAsString();
    final fields = text.substring(text.lastIndexOf(')') + 2).split(' ');
    final ticks = await Process.run('getconf', ['CLK_TCK']);
    if (ticks.exitCode != 0) return null;
    return ((int.parse(fields[11]) + int.parse(fields[12])) * 1000000) ~/
        int.parse((ticks.stdout as String).trim());
  }
  return null;
}
