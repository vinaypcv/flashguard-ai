# Verification record

The `/verify-storage-pr` command is a review procedure in `.claude/commands/verify-storage-pr.md`. Claude Code was not installed in the local environment during this change, so this document does not claim an agent tool invocation, failed agent test, or agent-driven fix. A genuine Claude trace can be appended after that workflow is run on a feature branch.

## What the bit-flip case proves

`inject_silent_bit_flip` mutates one byte inside the `mdat` payload of a sandboxed MP4 fixture. The Python test checks that file length and MP4 box structure stay unchanged while SHA-256 changes. The Flutter test supplies the original trusted digest to `verifiedOffload` and checks that the mutated source is rejected. Without a trusted baseline digest, hashing a corrupted source and its faithful copy cannot identify the corruption as pre-existing.

## Checkpoint invariant

A `.checkpoint.json` sidecar records the source path, length, full source SHA-256, complete-block offset, block size, and each completed block's SHA-256. Version 2 snapshots include a metadata checksum and generation number. Each update is staged and flushed before the current snapshot rotates to `.checkpoint.json.bak`; recovery validates metadata and re-hashes every saved source/part block, trying the backup if the newest snapshot is damaged. Version 1 sidecars remain readable and are upgraded on the next checkpoint. The final file is promoted only after the completed part and current source match the original source digest.

`flush: true` and same-directory rename reduce the risk of torn checkpoint metadata. They do not establish power-loss durability on every filesystem because this prototype does not issue platform-specific file and directory sync operations. Mobile document-provider resume is also unverified.

Byte-for-byte copy verification and media structure inspection are reported separately. A malformed or truncated media file can still be preserved as a byte-verified archival copy; the UI now shows both results.

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

## Feature branch result (2026-11-16)

On `feature/verified-storage-v2`, after the checkpoint journal and integrity-state changes:

```text
flutter test --reporter expanded
00:10 +14: All tests passed!

flutter analyze --fatal-infos
No issues found! (ran in 8.9s)

python -m unittest discover -p 'test_*.py' -v
Ran 3 tests in 0.103s
OK
```

The MCP tests ran in the workspace-configured Python 3.14.5 virtual environment. The Flutter SDK is the repository's embedded Windows SDK. No Windows release build or power-loss test was run.

## Batch processing result (2026-11-16)

The batch worker now enumerates files recursively without following links and writes each file beneath the destination using its source-relative directory. Per-file failures are recorded in the summary while later files continue. `startVerifiedBatch` exposes progress events and pause, resume, and cancel controls; commands take effect at block checkpoints, preserving the active `.part` file and its validated checkpoint for a later run. `runVerifiedBatch` remains available for callers that only need the completed summary.

The deterministic Flutter cases cover nested destination paths, rejection of a destination inside its source tree, a simulated permission denial that does not stop neighboring transfers, an injected interruption followed by a checkpoint-block bit flip and safe restart, and progress/pause/cancel/restart behavior.

```text
flutter test --reporter expanded
00:36 +18: All tests passed!

flutter analyze --fatal-infos
No issues found! (ran in 50.0s)

python -m unittest discover -p test_*.py -v
Ran 3 tests in 0.060s
OK
```

The permission scenario is deterministic fault injection, not an operating-system ACL test. Pause and cancel are honored at transfer checkpoints; the initial whole-source SHA-256 pass is not interruptible. These tests do not establish physical-device disconnect behavior, power-loss durability, or performance under large production media workloads.

Android and iOS native stubs were not compiled or exercised on mobile hardware in this Windows run. They return `VOLUME_API_NOT_WIRED` until the platform adapters are implemented.

## Milestone 3, Increment 2: recovery properties (2026-11-16)

The transfer lifecycle is an in-memory `TransferStateMachine`. It validates the
`pending → hashingSource → copying → checkpointed → verifying → promoting → committed`
path, with pause, cancellation, and failure transitions. A checkpoint is a
separate disk artifact; a lifecycle event does not imply a journal write. A
committed result follows SHA-256 verification of the part and a second check of
the promoted final file and current source. Reuse of an existing matching file
also rehashes that file and the current source.

The deterministic test uses seeds `0x5a1700` through `0x5a1763` (100 scenarios).
Each failure reports its decimal seed, size, block size, interruption count,
corruption and conflict flags, and transition history. The harness varies zero
and nonzero source lengths, checkpoint block size, interruption threshold,
repeated retries, part and journal damage, nested directories, existing names,
and source mutation. Focused tests cover illegal lifecycle transitions,
destination-root escape, and a conflict injected immediately before promotion.

### Assumptions and failure model

1. Matching source and destination SHA-256 is asserted after success. The source
   is assumed stable while each hash is computed; SHA-256 collision resistance
   is assumed. A trusted `expectedSha256` is needed to detect corruption that
   predates the transfer.
2. Recovered offsets must be between zero and the current source length and
   have the expected number of block hashes. The harness checks every readable
   checkpoint's bound after an interruption.
3. A checkpoint is accepted only after its version, metadata checksum (v2),
   source identity, source digest, block size, offset, part length, and every
   referenced source and part block digest are checked. Version 1 metadata has
   no metadata checksum, but its referenced bytes are still rehashed.
4. A damaged part fails block validation on restart or final whole-file digest
   verification. Neither case may promote it as verified.
5. Failed and cancelled lifecycle instances are terminal. A new attempt can
   succeed only after running verification again; a complete saved checkpoint
   can legitimately be verified and promoted on retry.
6. Existing destinations are reverified and reused only on digest match;
   conflicting content gets a numbered name. Promotion checks for a newly
   appearing destination and reports a conflict without replacing it.
7. Cancellation is cooperative at saved block checkpoints. Recovery still
   revalidates the saved metadata and part blocks. The initial source hash is
   not interruptible. An uncheckpointed part tail is truncated on resume.
8. Destination directory paths are normalized against the selected root, and
   existing directory symlinks and sidecar symlinks are checked before use.
   The batch enumerator does not follow source symlinks.

The fault harness injects failures through callbacks and local files, not a
physical disconnect, process power cut, or concurrent adversarial writer.
`flush` and same-directory rename do not establish power-loss durability. A
native implementation must sync the part and journal files, perform a
no-replace promotion atomically, and sync the containing directories on each
supported filesystem. The current pre-rename conflict check cannot eliminate a
cross-process race on platforms whose rename replaces an existing target.

### Verification commands and observed results

On `feature/verified-storage-v2`, using the repository's embedded Windows
Flutter SDK and MCP Python virtual environment:

```text
dart format app/lib app/test
Formatted 11 files (0 changed) in the final pass.

flutter test --reporter expanded --concurrency=1 --timeout 2m
09:55 +26: All tests passed!

flutter analyze --fatal-infos
No issues found! (ran in 11.6s)

python -m unittest discover -p "test_*.py" -v
Ran 3 tests in 1.810s
OK

git diff --check
Exit code 0 (Git only warned about future CRLF conversion).
```

The 100-case property test has its own ten-minute timeout and passed in the
full suite. The default 30-second Flutter test timeout was too short for some
file-backed tests under this Windows host's variable I/O load; the final run
serialized test files and allowed two minutes per ordinary test. The attempted
pre-edit baseline run overlapped an edit during compilation, so it cannot be
counted as a clean baseline result. The final suite includes all 22 previously
existing tests, and all passed. No mobile hardware or physical power-loss test
was performed.
