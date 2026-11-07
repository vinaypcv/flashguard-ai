# FlashGuard Engineering Rules for AI Agents

1. **No Main-Thread Disk I/O:** Never call synchronous file operations (`readAsBytesSync`, `copySync`) on the main UI isolate. Always use `Isolate.run()` or streaming `Stream<List<int>>`.
2. **Verify Container Headers, Not Extensions:** Never trust `.mp4` or `.jpg` file extensions alone. Validate supported media with `IntegrityEngine.inspectMediaHeader`.
3. **Deterministic Error Handling:** Handle `FileSystemException` (sudden disconnect / ENOSPC) without promoting a partial copy or deleting the source. Resume support requires a separate design and tests.
4. **Mandatory Verification:** Before concluding any task, run `flutter test` and verify against `mcp-server` fault fixtures.
