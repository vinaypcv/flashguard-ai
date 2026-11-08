# Verification record

The `/verify-storage-pr` command is a review procedure in `.claude/commands/verify-storage-pr.md`. Claude Code was not installed in the local environment during this change, so this document does not claim an agent tool invocation, failed agent test, or agent-driven fix. A genuine Claude trace can be appended after that workflow is run on a feature branch.

## What the bit-flip case proves

`inject_silent_bit_flip` mutates one byte inside the `mdat` payload of a sandboxed MP4 fixture. The Python test checks that file length and MP4 box structure stay unchanged while SHA-256 changes. The Flutter test supplies the original trusted digest to `verifiedOffload` and checks that the mutated source is rejected. Without a trusted baseline digest, hashing a corrupted source and its faithful copy cannot identify the corruption as pre-existing.

## Checkpoint invariant

A `.checkpoint.json` sidecar records the source path, length, full source SHA-256, complete-block offset, block size, and each completed block's SHA-256. Resume validates the current source digest and both copies of each saved block before reusing bytes. A stale or modified checkpoint is discarded. The final file is promoted only after the completed part and current source match the original source digest. This is a directory-backed prototype; mobile document-provider resume and power-loss durability are not verified.

## Reproduce

From `mcp-server`: `python -m unittest discover -p 'test_*.py' -v`.

From `app`: `flutter analyze --fatal-infos` and `flutter test --reporter expanded`.

CI: `.github/workflows/verify.yml` runs the same suites on pushes and pull requests.

## Local result (2026-11-07)

```text
python -m unittest discover -p 'test_*.py' -v
Ran 3 tests in 2.086s
OK

flutter analyze --fatal-infos
No issues found! (ran in 67.6s)

flutter test --reporter expanded
00:37 +11: All tests passed!
```

Android and iOS native stubs were not compiled or exercised on mobile hardware in this Windows run. They return `VOLUME_API_NOT_WIRED` until the platform adapters are implemented.
