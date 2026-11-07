Run a storage reliability audit on the current working tree:
1. Inspect `git diff` and new files for blocking UI-isolate I/O, source deletion, and unchecked destination replacement.
2. From `mcp-server`, run `python -m unittest discover -p 'test_*.py' -v`. These tests create virtual MP4 and JPEG fixtures and check the disconnect and sandbox boundaries.
3. From `app`, run `flutter analyze --fatal-infos` and `flutter test --reporter expanded`. The Dart tests create their own deterministic fixtures.
4. Report pass/fail results and any edge cases caught. Include throughput overhead only if it was measured.
