import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

enum PromotionFailure { conflict, unsupported, io, invalidPath, verification }

/// [destinationMayExist] means the move completed, or its outcome is uncertain.
/// Callers must retain the final path and reverify it rather than delete it.
class PromotionException extends FileSystemException {
  final PromotionFailure kind;
  final bool destinationMayExist;

  PromotionException(this.kind, String message, String path,
      {int? nativeCode, this.destinationMayExist = false})
      : super(message, path,
            nativeCode == null ? null : OSError(message, nativeCode));
}

class PromotionCapabilities {
  final bool atomicNoReplace;
  final bool nativeFileSync;
  final bool directorySync;
  final String description;

  const PromotionCapabilities(
      {required this.atomicNoReplace,
      required this.nativeFileSync,
      required this.directorySync,
      required this.description});
}

/// Evidence of API completion, never a claim of tested power-loss persistence.
class StorageCommitEvidence {
  final PromotionCapabilities capabilities;
  final bool fileSyncCompleted;
  final bool directorySyncCompleted;

  const StorageCommitEvidence(this.capabilities,
      {required this.fileSyncCompleted, required this.directorySyncCompleted});
}

abstract interface class AtomicFilePromoter {
  Future<PromotionCapabilities> capabilities(Directory directory);
  Future<TransferWorkspaceLease> acquireWorkspace(File destination);
  Future<void> syncFile(File file);
  Future<void> syncDirectory(Directory directory);
  Future<void> promoteNoReplace(File temporary, File destination);
}

abstract interface class TransferWorkspaceLease {
  Future<void> release();
}

class _NativeWorkspaceLease implements TransferWorkspaceLease {
  int? _handle;
  _NativeWorkspaceLease(this._handle);

  @override
  Future<void> release() async {
    final handle = _handle;
    if (handle == null) return;
    _handle = null;
    await Isolate.run(() => _closeWorkspace(handle));
  }
}

/// Native calls run on a worker isolate, including volume queries and sync.
/// Only same-directory regular-file promotion is accepted. Directories must
/// remain stable; this is not a sandbox against hostile namespace replacement.
class NativeAtomicFilePromoter implements AtomicFilePromoter {
  const NativeAtomicFilePromoter();

  @override
  Future<TransferWorkspaceLease> acquireWorkspace(File destination) async {
    final path = '${destination.absolute.path}.transfer.lock';
    if (await FileSystemEntity.type(path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw PromotionException(PromotionFailure.invalidPath,
          'Workspace lock must not be a symbolic link', path);
    }
    final handle = await Isolate.run(() => _openWorkspace(path));
    return _NativeWorkspaceLease(handle);
  }

  @override
  Future<PromotionCapabilities> capabilities(Directory directory) async {
    final path = await directory.resolveSymbolicLinks();
    return Isolate.run(() => _capabilities(path));
  }

  @override
  Future<void> promoteNoReplace(File temporary, File destination) async {
    final parent = await temporary.parent.resolveSymbolicLinks();
    final targetParent = await destination.parent.resolveSymbolicLinks();
    if ((Platform.isWindows ? parent.toLowerCase() : parent) !=
            (Platform.isWindows ? targetParent.toLowerCase() : targetParent) ||
        await FileSystemEntity.type(temporary.path, followLinks: false) !=
            FileSystemEntityType.file) {
      throw PromotionException(
          PromotionFailure.invalidPath,
          'Promotion requires a regular part in the same directory',
          destination.path);
    }
    final from =
        '$parent${Platform.pathSeparator}${temporary.uri.pathSegments.last}';
    final to =
        '$parent${Platform.pathSeparator}${destination.uri.pathSegments.last}';
    if (from == to) {
      throw PromotionException(PromotionFailure.invalidPath,
          'Temporary and final paths must differ', to);
    }
    await Isolate.run(() {
      final capability = _capabilities(parent);
      if (!capability.atomicNoReplace) {
        throw PromotionException(
            PromotionFailure.unsupported, capability.description, to);
      }
      if (Platform.isWindows) {
        _windowsMove(from, to);
      } else {
        _linuxMove(from, to);
      }
    });
  }

  @override
  Future<void> syncFile(File file) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw PromotionException(PromotionFailure.invalidPath,
          'Cannot sync a non-regular file', file.path);
    }
    final path = file.absolute.path;
    await Isolate.run(() {
      if (Platform.isWindows) {
        _windowsSync(path);
      } else if (Platform.isLinux) {
        _linuxSync(path);
      } else {
        throw PromotionException(
            PromotionFailure.unsupported, 'Native sync unavailable', path);
      }
    });
  }

  @override
  Future<void> syncDirectory(Directory directory) async {
    final path = await directory.resolveSymbolicLinks();
    if (!Platform.isLinux) {
      throw PromotionException(
          PromotionFailure.unsupported,
          'Parent directory synchronization is not implemented on this platform',
          path);
    }
    await Isolate.run(() => _linuxSync(path));
  }
}

PromotionCapabilities _capabilities(String directory) {
  if (Platform.isWindows) {
    return using((arena) {
      final kernel = DynamicLibrary.open('kernel32.dll');
      final lastError = kernel
          .lookupFunction<Uint32 Function(), int Function()>('GetLastError',
              isLeaf: true);
      final volumePath = kernel.lookupFunction<
          Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
          int Function(
              Pointer<Utf16>, Pointer<Utf16>, int)>('GetVolumePathNameW');
      final volumeInfo = kernel.lookupFunction<
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
      final driveType = kernel.lookupFunction<Uint32 Function(Pointer<Utf16>),
          int Function(Pointer<Utf16>)>('GetDriveTypeW');
      final root = arena<Uint16>(32768).cast<Utf16>();
      final fs = arena<Uint16>(64).cast<Utf16>();
      lastError(); // Resolve the FFI trampoline before the fallible call.
      if (volumePath(directory.toNativeUtf16(allocator: arena), root, 32768) ==
              0 ||
          volumeInfo(root, nullptr, 0, nullptr, nullptr, nullptr, fs, 64) ==
              0) {
        _windowsError(directory, lastError());
      }
      final type = driveType(root);
      final name = fs.toDartString();
      // Narrow support to local NTFS until other filesystems are validated.
      final supported = (type == 2 || type == 3) && name == 'NTFS';
      return PromotionCapabilities(
          atomicNoReplace: supported,
          nativeFileSync: supported,
          directorySync: false,
          description: 'Windows $name driveType=$type; local NTFS only; '
              'FlushFileBuffers available, directory sync unavailable');
    });
  }
  if (Platform.isLinux) {
    try {
      final libc = DynamicLibrary.open('libc.so.6');
      libc.lookup<
          NativeFunction<
              Int32 Function(Int32, Pointer<Utf8>, Int32, Pointer<Utf8>,
                  Uint32)>>('renameat2');
      return const PromotionCapabilities(
          atomicNoReplace: true,
          nativeFileSync: true,
          directorySync: true,
          description:
              'Linux glibc renameat2; filesystem support checked by operation; fsync required');
    } on ArgumentError {
      // Missing symbol or library: no fallback to rename.
    }
  }
  return const PromotionCapabilities(
      atomicNoReplace: false,
      nativeFileSync: false,
      directorySync: false,
      description: 'No verified native no-replace implementation available');
}

String _windowsPath(String path) {
  final normalized = path.replaceAll('/', r'\');
  return normalized.startsWith(r'\\?\') ? normalized : '\\\\?\\$normalized';
}

void _windowsMove(String from, String to) {
  using((arena) {
    final kernel = DynamicLibrary.open('kernel32.dll');
    final lastError = kernel.lookupFunction<Uint32 Function(), int Function()>(
        'GetLastError',
        isLeaf: true);
    final move = kernel.lookupFunction<
        Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
        int Function(Pointer<Utf16>, Pointer<Utf16>, int)>('MoveFileExW');
    final attributes = kernel.lookupFunction<Uint32 Function(Pointer<Utf16>),
        int Function(Pointer<Utf16>)>('GetFileAttributesW');
    final fromPath = _windowsPath(from).toNativeUtf16(allocator: arena);
    final toPath = _windowsPath(to).toNativeUtf16(allocator: arena);
    lastError();
    // No REPLACE_EXISTING, COPY_ALLOWED, or delayed operation flags.
    if (move(fromPath, toPath, 0) == 0) {
      final code = lastError();
      // The VM can disturb thread-local last-error state. Occupancy observed
      // AFTER native failure provides a reliable conflict outcome without
      // weakening no-replace semantics or attempting another move.
      if (attributes(toPath) != 0xffffffff) {
        throw PromotionException(PromotionFailure.conflict,
            'Native promotion failed and destination is occupied', to,
            nativeCode: code == 0 ? null : code);
      }
      _windowsError(to, code);
    }
  });
}

Never _windowsError(String path, int code) {
  final kind = switch (code) {
    80 || 183 => PromotionFailure.conflict,
    1 || 17 || 50 || 120 => PromotionFailure.unsupported,
    _ => PromotionFailure.io,
  };
  throw PromotionException(
      kind, 'Windows native storage operation failed', path,
      nativeCode: code);
}

void _windowsSync(String path) {
  using((arena) {
    final kernel = DynamicLibrary.open('kernel32.dll');
    final lastError = kernel.lookupFunction<Uint32 Function(), int Function()>(
        'GetLastError',
        isLeaf: true);
    final open = kernel.lookupFunction<
        IntPtr Function(Pointer<Utf16>, Uint32, Uint32, Pointer<Void>, Uint32,
            Uint32, IntPtr),
        int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int,
            int)>('CreateFileW');
    final flush =
        kernel.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
            'FlushFileBuffers');
    final close =
        kernel.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
            'CloseHandle');
    lastError();
    final handle = open(_windowsPath(path).toNativeUtf16(allocator: arena),
        0x40000000, 7, nullptr, 3, 0x80, 0); // WRITE, share all, OPEN_EXISTING.
    if (handle == -1) _windowsError(path, lastError());
    try {
      if (flush(handle) == 0) _windowsError(path, lastError());
    } finally {
      close(handle);
    }
  });
}

void _linuxMove(String from, String to) {
  using((arena) {
    final libc = DynamicLibrary.open('libc.so.6');
    final errno = libc.lookupFunction<Pointer<Int32> Function(),
        Pointer<Int32> Function()>('__errno_location');
    final errorSlot = errno();
    final move = libc.lookupFunction<
        Int32 Function(Int32, Pointer<Utf8>, Int32, Pointer<Utf8>, Uint32),
        int Function(int, Pointer<Utf8>, int, Pointer<Utf8>, int)>('renameat2');
    if (move(-100, from.toNativeUtf8(allocator: arena), -100,
            to.toNativeUtf8(allocator: arena), 1) !=
        0) {
      _linuxError(to, errorSlot.value);
    }
  });
}

Never _linuxError(String path, int code) {
  final kind = switch (code) {
    17 => PromotionFailure.conflict,
    18 || 22 || 38 || 95 => PromotionFailure.unsupported,
    _ => PromotionFailure.io,
  };
  throw PromotionException(kind, 'Linux native storage operation failed', path,
      nativeCode: code);
}

void _linuxSync(String path) {
  using((arena) {
    final libc = DynamicLibrary.open('libc.so.6');
    final errno = libc.lookupFunction<Pointer<Int32> Function(),
        Pointer<Int32> Function()>('__errno_location');
    final errorSlot = errno();
    final open = libc.lookupFunction<Int32 Function(Pointer<Utf8>, Int32),
        int Function(Pointer<Utf8>, int)>('open');
    final sync =
        libc.lookupFunction<Int32 Function(Int32), int Function(int)>('fsync');
    final close =
        libc.lookupFunction<Int32 Function(Int32), int Function(int)>('close');
    final fd =
        open(path.toNativeUtf8(allocator: arena), 0); // O_RDONLY; no creation.
    if (fd < 0) _linuxError(path, errorSlot.value);
    try {
      if (sync(fd) != 0) _linuxError(path, errorSlot.value);
    } finally {
      close(fd);
    }
  });
}

// The lock file is deliberately retained. Unlinking it would allow waiters to
// lock different inodes. Native handles/locks are released on process exit.
int _openWorkspace(String path) {
  return using((arena) {
    if (Platform.isWindows) {
      final kernel = DynamicLibrary.open('kernel32.dll');
      final open = kernel.lookupFunction<
          IntPtr Function(Pointer<Utf16>, Uint32, Uint32, Pointer<Void>, Uint32,
              Uint32, IntPtr),
          int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int,
              int)>('CreateFileW');
      final handle = open(_windowsPath(path).toNativeUtf16(allocator: arena),
          0x40000000, 0, nullptr, 4, 0x80, 0); // No sharing, OPEN_ALWAYS.
      if (handle == -1) {
        throw PromotionException(PromotionFailure.io,
            'Workspace is busy or inaccessible; no part was opened', path);
      }
      return handle;
    }
    if (Platform.isLinux) {
      final libc = DynamicLibrary.open('libc.so.6');
      final open = libc.lookupFunction<
          Int32 Function(Pointer<Utf8>, Int32, Uint32),
          int Function(Pointer<Utf8>, int, int)>('open');
      final flock = libc.lookupFunction<Int32 Function(Int32, Int32),
          int Function(int, int)>('flock');
      final close = libc
          .lookupFunction<Int32 Function(Int32), int Function(int)>('close');
      final fd = open(path.toNativeUtf8(allocator: arena), 0x42,
          0x180); // RDWR|CREAT, 0600.
      if (fd >= 0) {
        if (flock(fd, 6) == 0) return fd; // LOCK_EX | LOCK_NB.
        close(fd);
      }
      throw PromotionException(PromotionFailure.io,
          'Workspace is busy or inaccessible; no part was opened', path);
    }
    throw PromotionException(PromotionFailure.unsupported,
        'No workspace locking implementation', path);
  });
}

void _closeWorkspace(int handle) {
  if (Platform.isWindows) {
    DynamicLibrary.open('kernel32.dll')
        .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
            'CloseHandle')(handle);
  } else {
    DynamicLibrary.open('libc.so.6')
            .lookupFunction<Int32 Function(Int32), int Function(int)>('close')(
        handle);
  }
}
