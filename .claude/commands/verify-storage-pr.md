Run a storage reliability audit on the current working tree:
1. Inspect `git diff` and new files for blocking UI-isolate I/O, source deletion, and unchecked destination replacement.
2. From `mcp-server`, run `python -m unittest discover -p 'test_*.py' -v`. Confirm the bit-flip tool changes SHA-256 without changing file size or MP4 box structure, and that the disconnect and sandbox boundary tests pass.
3. From `app`, run `flutter analyze --fatal-infos` and `flutter test --reporter expanded`. The Dart tests create their own deterministic fixtures.
4. Check that resume validates saved blocks, and that any claim of pre-existing bit-rot detection uses a trusted original digest. Report pass/fail results and any edge cases caught. Include throughput overhead only if it was measured.
