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

## Milestone 3, Increment 3: native promotion (2026-11-16)

This section supersedes Increment 2's pre-rename conflict-check limitation.
The baseline was recorded before edits at `bb9a276`: all 26 Flutter tests
passed in 2:55, including all 100 seeds `0x5a1700` through `0x5a1763`.

### Native operations and supported scope

`AtomicFilePromoter` provides injectable capabilities, workspace ownership,
file and directory sync, and no-replace promotion. Native disk operations run
inside `Isolate.run`, including when called directly from the UI isolate.
`PromotionException` distinguishes conflict, unsupported capability, invalid
paths, I/O failure, and failed verification. It remains a
`FileSystemException` for existing callers.

| Platform | Promotion | Native sync requests | Support boundary |
| --- | --- | --- | --- |
| Windows | `MoveFileExW` with flags **0** | `FlushFileBuffers` on part and journal files | Local fixed/removable NTFS only; directory sync unavailable |
| Linux | glibc `renameat2` with `RENAME_NOREPLACE` | `fsync` on part/journal files and their containing directory | Requires libc symbol, kernel, and filesystem support; runtime rejection fails closed |
| Others | Typed unsupported result | Unavailable | No overwrite-capable rename fallback |

The Windows flags omit both `MOVEFILE_REPLACE_EXISTING` and
`MOVEFILE_COPY_ALLOWED`. The promoter requires the same resolved parent
directory for both paths and a regular, non-symlink part. The kernel operation
is responsible for refusing an occupied destination; no existence precheck is
used to authorize a potentially replacing rename. A failed Windows move also
checks destination occupancy to classify conflicts: Dart FFI's thread-local
`GetLastError` was observed returning zero on some failed calls. Other failures
remain typed I/O errors when no reliable native diagnostic is available.

Linux `EEXIST` is a conflict; `EXDEV`, `EINVAL`, `ENOSYS`, and `EOPNOTSUPP`
are unsupported results. Symbol availability is a preliminary capability,
not proof that a specific mounted filesystem implements the operation. No
ordinary rename is substituted after a failure.

Engine jobs also acquire an OS lock on a persistent `.transfer.lock` sidecar
before opening shared part/journal files. Windows uses an exclusive-sharing
`CreateFileW` handle; Linux uses nonblocking exclusive `flock`. Busy or
inaccessible workspaces fail explicitly. The lock file stays in place to
prevent different writers locking different inodes; normal completion,
cancellation, and exceptions release the handle. Process termination releases
the OS lock. Forcibly killing only a Dart isolate while it owns a native handle
can leave the lease held until the host process exits; abrupt isolate kill is
not a supported cancellation mechanism.

### Commit order and recovery

1. Copy and flush part blocks; stage, flush, and rotate the existing v2 journal.
   Resume still validates metadata, bounds, source identity, and every saved
   source/part block. The checkpoint schema and v1 compatibility are preserved.
2. Close the part, compare its SHA-256 and the current source against the
   original source digest, and inspect media structure.
3. Request native synchronization of the part and available primary/backup
   journals. Sync the containing directory when supported. A sync failure
   prevents promotion.
4. Enter `promoting`, then issue the native no-replace operation. A conflict
   retains the competing destination and the recovery files; a later attempt
   follows the existing reverify-or-numbered-name policy.
5. Sync the parent after the move when supported, then reverify final type,
   size, digest, and current source size/digest. Only then enter `committed`.
6. Remove checkpoint sidecars as best-effort cleanup. Retain the lock inode.
   Cleanup failure cannot mask the already verified commit.

After a completed move, any sync or verification failure carries
`destinationMayExist: true` and the retained final path. The file is logically
unverified: no successful audit is returned. The engine never deletes or
renames that path on failure because another writer could have replaced it.
Retry rehashes it: matching bytes can be reused; different bytes are preserved
and a numbered destination is selected. This also covers a move that completed
before its caller observed completion. Checkpoint presence never establishes
that a final file is verified. The source is never deleted.

`FileAuditResult.storageCommitEvidence` records which native sync requests
completed. Reusing an existing copy makes no new sync claim and leaves that
field null. `committed` still denotes a byte-verified application result,
not a power-loss durability guarantee.

### Evidence and limitations

Native tests ran on Windows build `10.0.26300.0`, x64, with Dart 3.13.7 and
the embedded Flutter SDK. The native capability check confirmed local NTFS in
the temporary test directory. Four native tests cover Unicode paths,
`FlushFileBuffers`, existing destination preservation, same-directory
enforcement, workspace exclusion/reacquisition, and eight rounds of two
independent isolate writers released through a synchronization barrier. Each
round requires exactly one success and one conflict, matching final bytes,
an intact losing part, and removal of only the winning part.

The engine/fault tests cover unsupported capabilities, failure after part
verification, damaged journals on retry, pre-promotion and post-promotion sync
failures, a late competing writer, retry naming, incomplete promotion,
post-promotion replacement, shared-workspace exclusion, and sync evidence.
These tests use callbacks/completers rather than timing sleeps. A native
move followed by injected failure demonstrates restart revalidation; it does
not simulate a real process power cut.

Linux execution was not available in this Windows session. The CI workflow
now runs the native and regression suites on both Windows and Linux, but no
remote CI result is claimed. Windows network shares, ReFS, FAT/exFAT, other
platforms, missing Linux native symbols, and unsupported Linux kernel/filesystem
operations fail closed. No physical tests were performed on external media.

Power-loss durability remains unproven. Windows has no implemented parent
directory synchronization; Linux sync completion is subject to actual
filesystem/device behavior. Newly created ancestor directories and checkpoint
cleanup are not individually synced. Namespace and file contents must remain
stable during verification: atomic no-replace protects competing creators,
not an adversary modifying a winning file or replacing parent directories,
symlinks, reparse points, or hard links. Native lock ownership protects
cooperating FlashGuard jobs, not arbitrary external part-file mutations.

Authoritative API references:

- [Microsoft MoveFileExW flags and cross-volume behavior](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-movefileexw)
- [Microsoft FlushFileBuffers semantics](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-flushfilebuffers)
- [Linux renameat2 flags and filesystem support](https://man7.org/linux/man-pages/man2/rename.2.html)
- [Linux fsync and parent-directory synchronization](https://man7.org/linux/man-pages/man2/fsync.2.html)

### Final verification

```text
# Dependency resolution used the already cached ffi 2.2.0 package.
flutter pub get --offline
Got dependencies!

dart format lib test
Formatted 14 files.

flutter test --no-pub --concurrency=1 --timeout 2m --reporter expanded
03:16 +39: All tests passed!

flutter analyze --no-pub --fatal-infos
No issues found! (ran in 8.0s)

# From mcp-server, using .venv/Scripts/python.exe:
python -m unittest discover -p "test_*.py" -v
Ran 3 tests in 0.249s
OK

git diff --check
Exit code 0; only Git line-ending conversion warnings.
```

The exact requested Flutter test command was attempted, but online dependency
resolution stalled. After successful offline resolution, `--no-pub` was used
for the full test and analysis runs; no tests were excluded. All 26 prior tests
and all 100 original generated seeds passed, along with 13 added tests. The
four native Windows tests were executed, not skipped. Eight synchronized
writer races passed in that native suite. No remote CI run, independent
process-writer stress test, or physical crash-durability test is claimed.

Changes remain uncommitted on `feature/verified-storage-v2`. The preexisting
untracked `.vscode/` directory was not modified.

## Milestone 3, Increment 4: real processes and measured storage (2026-11-16)

Increment 3 was explicitly preserved and pushed as `9d6495e`
(`feat: add native atomic promotion and concurrency verification`) before this
work. The clean pre-edit Increment 4 baseline passed all 39 Flutter tests in
4:32. Increment 4 remains uncommitted.

### Production path and new experiments

`benchmarks/storage_reliability/run.dart` starts a standalone Dart controller.
Its OS-process worker calls the existing `IntegrityEngine.verifiedOffload` or,
for the separate native races, `NativeAtomicFilePromoter.promoteNoReplace`.
The engine is usable without a Flutter UI or method-channel stubs. Optional
`TransferDiagnostics` and `onProbe` observations expose real operation boundaries
and completed logical write counts; the checkpoint schema, default public API,
source-preservation policy, and cancellation behavior are unchanged.

The controller waits for flushed JSON IPC gates, sends a real process kill,
waits for exit, inspects the part/journal, and launches a fresh VM. Tests cover
an uncheckpointed flushed block, a saved checkpoint, an opened/read verification
stream, immediately before promotion, and immediately after native promotion.
The verification kill suspends the first read chunk before hashing that chunk;
it does not claim an arbitrary kill inside a native syscall or SHA instruction.
Each restart checks the expected reuse offset, original source digest and final
digest. A killed process's native workspace lock must be reacquirable.

Each platform also ran five barrier-controlled races between different PIDs and
different native part files, plus an occupied-destination race. Exactly one
writer may win an empty destination; both must fail on the occupied target.
Losing parts and existing final content must remain intact. A separate full
engine experiment demonstrates workspace exclusion, process-death lock release,
rejection of another source's checkpoint, and numbered-name retry behavior.
No timing sleeps authorize termination or release the writer barriers.

### Actual platform evidence

| Environment | Filesystem used for fixtures | Reliability result |
| --- | --- | --- |
| Windows x64, build 26300, Dart 3.13.7 | Local NTFS on C:, bounded temporary fixtures | 12 passed, 0 failed, 1 explicit disk-full skip |
| Ubuntu 24.04 in WSL2, kernel `6.18.33.1-microsoft-standard-WSL2`, Dart 3.13.7 | ext4, `/dev/sdd`, fixtures under `/tmp` | 12 passed, 0 failed, 1 explicit disk-full skip |

These are executed results, not inferred from workflow YAML. The Linux process
experiments exercised real glibc `renameat2(RENAME_NOREPLACE)`, `flock`, and
file/directory `fsync` on ext4. They used a workspace-local Linux Dart SDK and
translated package paths in ignored `.tools/`; no global toolchain was changed.
Remote CI for the new jobs has not run: the new workflow and harness are still
uncommitted. WSL execution does not establish bare-metal Linux behavior.

The JSON artifacts include UTC start/end times, actual platform/kernel and
filesystem, capability outcomes, base Git revision, dirty-tree flag, relevant
source SHA-256 values, seed, PIDs, kill exit codes, checkpoint snapshots,
transition histories, final digests and recovery outcomes. Records intentionally
contain expected failing child attempts inside a passing recovery experiment.
The default seed is `5904128`; native race rounds vary it by round. Fixture
generation is deterministic and outside measured transfer intervals.

### Safe disk exhaustion and measured limitations

No disposable volume was supplied, so **real ENOSPC testing was SKIPPED** on
both systems. No system drive was deliberately filled, and no simulated fault
was labelled real disk exhaustion. The opt-in implementation requires matching
absolute approved paths, a regular approval marker, a non-system volume, bounded
capacity/allocation, and either a labelled tiny Windows volume outside C: or a
separately named disposable Linux tmpfs. It rejects filesystem roots, C:, shared
`/tmp`/`/dev/shm`, missing approvals, and normal oversized disks. The new policy
tests exercise rejections without allocating disk-filling data.

The opt-in test pauses an actual engine worker after its first checkpoint,
writes a private filler up to the allocation cap, requires real disk-full OS
errors from filler and production transfer, then removes its filler and
restarts. Cap exhaustion without ENOSPC is a skip. This path has been
implemented but has not been executed against an exhausted volume here. Only
its private new experiment subdirectory can be cleaned up; unrelated files
are never selected for deletion. See the harness README for prerequisites and
manual cleanup after a controller crash.

Benchmark samples use fresh destinations and an excluded warm-up. OS caches
are not evicted, so these are new-destination measurements rather than a
controlled cold-device-cache benchmark. Each sample starts a new JIT VM.
Reports distinguish engine latency from controller/VM startup latency and
separately measure hashing, recovery validation, copy/checkpoint work, final
verification, completed logical data/journal bytes, CPU time and RSS where
available. Physical write amplification is null; logical ratios exclude failed
partial writes, OS metadata and device counters. p95 remains null below 20
samples. No timing constants stand in for measured results.

Physical power-loss durability, hardware disconnect, real ENOSPC recovery,
external-device performance, and bare-metal Linux remain unproven. Native sync
API completion and process-kill recovery do not establish physical crash
consistency. Windows directory sync and the earlier namespace-stability
assumptions remain limitations.

### Commands and observed verification

```text
dart format app/lib app/test app/tool benchmarks/storage_reliability

# From app, using the embedded Flutter SDK:
flutter test --no-pub --concurrency=1 --timeout 2m --reporter expanded
04:03 +43: All tests passed!

flutter analyze --no-pub --fatal-infos
No issues found! (ran in 222.6s)

# From mcp-server, using .venv/Scripts/python.exe:
python -m unittest discover -p "test_*.py" -v
Ran 3 tests in 2.203s
OK
```

All 39 existing tests and all 100 seeds `0x5a1700`–`0x5a1763` passed.
Four new tests verify diagnostic boundaries/write counts, default disk-full
skip behavior, unsafe-volume rejection, and bounded benchmark/statistics options.
Formatting and final diff results plus measured benchmark tables follow below.

### Benchmark results and commands

Each main benchmark size has one excluded warm-up and three measured fresh
worker processes. All six size/platform experiments passed, each with a
separate killed/restarted transfer. Disk-full remained an explicit skip in
each invocation. These are observations from this host, not speed guarantees.

| Platform | Size MiB | Median engine seconds | Median MiB/s | Median pre/post byte-verification seconds | Median journal bytes written |
| --- | ---: | ---: | ---: | ---: | ---: |
| Windows NTFS | 1 | 1.362315 | 0.7340 | 0.073076 | 443 |
| Windows NTFS | 16 | 4.147573 | 3.8577 | 0.889765 | 2,184 |
| Windows NTFS | 128 | 19.625512 | 6.5221 | 6.950253 | 47,598 |
| WSL2 ext4 | 1 | 1.405955 | 0.7113 | 0.091580 | 406 |
| WSL2 ext4 | 16 | 4.731474 | 3.3816 | 0.981255 | 2,036 |
| WSL2 ext4 | 128 | 30.069276 | 4.2568 | 7.050815 | 46,414 |

Initial source SHA-256 time is separately recorded in each sample's metrics.
For 128 MiB its median was 1.817199 s on Windows and 1.914433 s on WSL.
Median worker CPU time for that size was 13.21875 s / 13.05 s, and median
per-worker peak RSS was 271.50 / 254.12 MiB, respectively. Logical write ratios
were 1.000355 / 1.000346; physical device write amplification remains null.

| Size MiB | Reused MiB | Transferred by restart MiB | Windows restart engine seconds | WSL restart engine seconds |
| --- | ---: | ---: | ---: | ---: |
| 1 | 1 | 0 | 0.993061 | 0.477024 |
| 16 | 4 | 12 | 4.160384 | 3.689649 |
| 128 | 4 | 124 | 18.220621 | 26.166838 |

The separate uncheckpointed-block kill case required recopying its first
256 KiB. Checkpointed benchmark restarts reused their saved prefixes. Controller
latency, including VM startup/exit and IPC, is also available in raw JSON.
With three samples, p95 is intentionally null. The earlier two-sample Windows
smoke artifact is retained as an initial run, not pooled with the main results.

Exact Windows commands from the repository root:

```powershell
.\.tools\flutter\bin\dart.bat --packages=app/.dart_tool/package_config.json benchmarks/storage_reliability/run.dart --suite=reliability --rounds=5 --output=benchmarks/storage_reliability/results/windows-reliability.json
.\.tools\flutter\bin\dart.bat --packages=app/.dart_tool/package_config.json benchmarks/storage_reliability/run.dart --suite=benchmark --sizes-mib=1,16,128 --samples=3 --output=benchmarks/storage_reliability/results/windows-benchmarks.json
.\.tools\flutter\bin\dart.bat --packages=app/.dart_tool/package_config.json benchmarks/storage_reliability/run.dart --suite=smoke --output=benchmarks/storage_reliability/results/windows-smoke.json
```

WSL commands used for the actual Linux runs, with the repository location
parameterized for publication (workspace-local SDK and translated package
configuration were prepared under ignored `.tools/`). Set `$repoWslPath` to
the output of `wsl -d Ubuntu-24.04 -- wslpath -u (Get-Location).Path`:

```powershell
wsl -d Ubuntu-24.04 --cd "$repoWslPath" --exec "$repoWslPath/.tools/linux-dart/dart-sdk/bin/dart" "--packages=$repoWslPath/.tools/linux-package-config.json" benchmarks/storage_reliability/run.dart --suite=reliability --rounds=5 --output=benchmarks/storage_reliability/results/linux-wsl-reliability.json
wsl -d Ubuntu-24.04 --cd "$repoWslPath" --exec "$repoWslPath/.tools/linux-dart/dart-sdk/bin/dart" "--packages=$repoWslPath/.tools/linux-package-config.json" benchmarks/storage_reliability/run.dart --suite=benchmark --sizes-mib=1,16,128 --samples=3 --output=benchmarks/storage_reliability/results/linux-wsl-benchmarks.json
```

For normal Linux/CI, resolve dependencies with Flutter in `app` and use `dart`
on PATH with `--packages=app/.dart_tool/package_config.json`, as documented in
`benchmarks/storage_reliability/README.md`. Native SDK download URLs follow the
[official Dart SDK archive](https://dart.dev/get-dart/archive).

### Increment 4 file manifest

```text
.github/workflows/verify.yml
app/lib/core/integrity_engine.dart
app/lib/core/transfer_diagnostics.dart
app/test/reliability_diagnostics_test.dart
app/tool/storage_reliability/controller.dart
app/tool/storage_reliability/disk_full.dart
app/tool/storage_reliability/environment.dart
app/tool/storage_reliability/model.dart
app/tool/storage_reliability/process_worker.dart
app/tool/storage_reliability/worker.dart
benchmarks/storage_reliability/run.dart
benchmarks/storage_reliability/README.md
benchmarks/storage_reliability/results/windows-smoke.json
benchmarks/storage_reliability/results/windows-reliability.json
benchmarks/storage_reliability/results/windows-benchmarks.json
benchmarks/storage_reliability/results/linux-wsl-reliability.json
benchmarks/storage_reliability/results/linux-wsl-benchmarks.json
docs/VERIFICATION.md
```

The workflow adds independent Windows/Linux real-process jobs and a bounded
performance smoke job alongside the existing Flutter/MCP regressions. All
shared CI commands leave disk exhaustion disabled. JSON artifacts are uploaded
even after a failure. The preexisting `.vscode/` directory remains untouched.

Final formatting reported `Formatted 23 files (0 changed) in 0.10 seconds`.
`git diff --check` exited 0 (line-ending conversion warnings only).
`git status --short --branch` showed only the Increment 4 paths above and the
preexisting untracked `.vscode/`; the branch remains synchronized at Increment
3 commit `9d6495e`, with no staged Increment 4 files and no Increment 4 commit.

## Milestone 3, Increment 5: phase profiling and controlled optimization (2026-11-17)

Increment 4 was reviewed, location strings in its evidence were redacted, and
its 18 intended files were committed and pushed as b8f2be7 before this work.
Measured values, seeds and hashes were preserved; private originals remain
under ignored .tools/. The pre-edit Flutter baseline passed 43/43 in 2:49.

The engine now has optional exclusive phase ledgers for setup, source hashing,
checkpoint loading/validation, source reads, block writes, part flushes, block
hashes, checkpoint serialization, checkpoint persistence, temporary-file
verification, source consistency, media inspection, durability, atomic promotion,
final verification, reuse and cleanup. Each phase records elapsed microseconds,
completed operation counts and observable read/write bytes. Total and
unattributed time expose coverage. Existing aggregate timing fields remain
available and must not be added to the exclusive ledger.

A fresh diagnostics instance is scoped to one attempt. Omitting it or setting
enabled:false disables phase collection. Tests demonstrate identical checkpoint
bytes and verified output with profiling on/off. Native I/O remains asynchronous
or on worker isolates. No source consistency check, trusted digest validation,
required data flush, checkpoint validation, native sync, or final-file
verification was removed.

The measured 128 MiB Windows profile has ten samples and a 19.463428 s median.
Median phase shares identify part flushes (24.97%) and journal persistence
(13.02%) as substantial costs. JSON serialization (0.04%) and source reads
(0.51%) are small in that run. Allocation/GC costs are not independently
isolated by a heap profiler; RSS is recorded. These observations selected an
opt-in 16 MiB checkpoint-block experiment against the 4 MiB baseline.
Buffer-reuse and JSON-encoding changes were deferred and not benchmarked.

The A/B runner uses one excluded warm-up per variant, at least ten matched
pairs per size, alternating order, fresh destinations and the same source.
Raw samples and per-phase distributions are preserved. The environments run
separately; caches and background host load are uncontrolled. p95 uses nearest
rank only at 20 or more samples per configuration and is null with ten.
The paired 5% observation band is descriptive, not statistical significance.
Distribution-median changes and paired-median changes are distinct statistics.

The larger-block option preserves the checkpoint protocol, but increases the
maximum uncheckpointed recopy tail from one 4 MiB block to one 16 MiB block and
uses a larger read buffer. Mismatched checkpoint block sizes are explicitly
rejected and restarted. Production defaults remain 4 MiB. CI process jobs
now cover both settings on Windows and Linux. No new remote CI run is claimed.

Completed Windows A/B: 60 measured transfers, all verified; each of the three
sizes has ten samples per variant. The 1 MiB distribution median regressed
28.30%, while its paired median change was -0.06% (5/10 pairs faster).
The 16 MiB/128 MiB median throughput changes were +18.99%/+36.48%; paired
median latency changes were -21.10%/-17.97% (7/10 and 9/10 pairs faster).
The raw 128 MiB maximum was 56.656 s for baseline and 109.892 s for candidate.
These outliers were retained. The candidate outlier included long source
consistency/final verification intervals as well as flush waits; no single
cause is established. The candidate is not a universal or tail-latency win.


The completed WSL A/B run also verified all 60 measured transfers. At
1 / 16 / 128 MiB, baseline median engine seconds were
0.970433 / 3.967589 / 31.533759; candidate medians were
0.964248 / 3.445992 / 21.587491. Median throughput changes were
+1.22% / +15.31% / +46.07%. Paired median latency changes were
-3.72% / -6.13% / -34.23%, with 6/10, 6/10 and 10/10 pairs faster.
These are WSL ext4 observations and must not be interpreted as a
cross-platform hardware comparison.

Both platforms used seed `5904128`. Each size/configuration has ten measured
samples plus an excluded warm-up, for 120 measured A/B transfers overall.
Raw samples, minimum/maximum, phase contribution distributions, metadata bytes,
CPU/RSS, order, process IDs and configuration are retained. Full tables,
candidate decision, commands and limitations are in
[INCREMENT5.md](../benchmarks/storage_reliability/INCREMENT5.md).
The two `.json.md` comparisons are generated from authoritative JSON.
Their paired-median labels were clarified after collection; source hashes
remain the collection-time values. Engine, diagnostics, controller and
options hashes still match the A/B artifacts. The later worker reporting fix
returns null for logicalWriteAmplification when profiling is disabled; it
does not change the enabled A/B path or any transfer operations.

The candidate remains opt-in. The 4 MiB production default is unchanged.
At 128 MiB, checkpoint counts decrease from 32 to 8 and flush counts from 33
to 9. Median journal bytes decrease from 47,502 to 5,447 on Windows and
46,318 to 5,151 on WSL. All required whole-file hash passes and native sync
requests remain present. A read-only consistency audit of all 120 samples
passed digest/state, fresh-copy byte, hash-byte, checkpoint/flush operation,
sync-count and nonnegative-unattributed-time assertions.
No Windows exploratory median throughput target was met by the candidate.
Buffer reuse, JSON-allocation and independent checkpoint-frequency changes
remain deferred and have no measured improvement claim.

### Process recovery and independent writers

| Executed environment | Block MiB | Passed | Failed | Explicit real ENOSPC skip |
| --- | ---: | ---: | ---: | ---: |
| Windows NTFS | 4 | 12 | 0 | 1 |
| Windows NTFS | 16 | 12 | 0 | 1 |
| WSL2 ext4 | 4 | 12 | 0 | 1 |
| WSL2 ext4 | 16 | 12 | 0 | 1 |

Each run executed five gate-synchronized process kills/restarts, five
independent-PID native races, one occupied-target race, and one full-engine
workspace exclusion/kill/restart experiment. This totals 48 passing
experiments across the four configurations, including 20 empty-target and
four occupied-target races. Larger-block kill fixtures contain at least two
blocks. Checkpointed prefixes were reused, uncheckpointed bytes recopied,
source/final digests matched, destination contents were preserved, and
process death released the workspace lock. Correctness jobs ran after the
A/B measurements; their timing is not used for performance claims.

The new CI matrix covers both block settings on Windows/Linux, with distinct
artifact names. No new remote CI result is claimed because Increment 5 is
uncommitted. No approved disposable volume was supplied: real ENOSPC remains
explicitly skipped. No physical power-loss, disconnect, external-device or
bare-metal Linux test was performed. Native sync completion and process-kill
recovery do not prove crash consistency; Windows directory sync and namespace
stability remain limitations.

### Final regression commands and observed results

The embedded `flutter.bat` bootstrap stalled, so the completed Flutter checks
used its pinned Dart executable and `flutter_tools.snapshot` directly.
No tests were excluded.

```text
# Repository root:
.tools\flutter\bin\cache\dart-sdk\bin\dart.exe format app/lib app/test app/tool benchmarks/storage_reliability
Formatted 26 files (0 changed) in 0.10 seconds.

# From app:
..\.tools\flutter\bin\cache\dart-sdk\bin\dart.exe ..\.tools\flutter\bin\cache\flutter_tools.snapshot test --no-pub --concurrency=1 --timeout 2m --reporter expanded
02:45 +47: All tests passed!

..\.tools\flutter\bin\cache\dart-sdk\bin\dart.exe ..\.tools\flutter\bin\cache\flutter_tools.snapshot analyze --no-pub --fatal-infos
No issues found! (ran in 10.2s)

# From mcp-server:
.venv\Scripts\python.exe -m unittest discover -p test_*.py -v
Ran 3 tests in 0.473s
OK

git diff --check
Exit code 0; Git line-ending conversion warnings only.

git diff --cached --name-only
Empty.
```

All 43 preexisting Flutter tests and all 100 original seeded recovery
scenarios passed. Four new tests verify profiling-on/off equivalence,
phase counters, incompatible-block checkpoint restart, paired A/B statistics
and report rendering, and publication path redaction.


The final reporting follow-up was checked with the existing bounded smoke
suite at `--profiling=false`: one excluded warm-up, two verified measured
copies, and a real killed/restarted copy all passed. The saved checkpoint
was reused, phase ledgers remained empty, and unavailable logical write
amplification was null. This two-sample smoke check is regression evidence,
not part of the ten-sample A/B performance claims.

```powershell
& $dart --packages=app/.dart_tool/package_config.json benchmarks/storage_reliability/run.dart --suite=smoke --profiling=false --output=benchmarks/storage_reliability/results/increment5-windows-profiling-disabled-smoke.json
```

The full 47-test regression ran before this reporting-only worker fix;
the production engine and verification behavior were unchanged. Final static
analysis after the fix reported no issues in 10.2 s.

### Increment 5 file manifest

```text
.github/workflows/verify.yml
app/lib/core/integrity_engine.dart
app/lib/core/transfer_diagnostics.dart
app/test/performance_profiling_test.dart
app/tool/storage_reliability/ab.dart
app/tool/storage_reliability/controller.dart
app/tool/storage_reliability/model.dart
app/tool/storage_reliability/publication.dart
app/tool/storage_reliability/worker.dart
benchmarks/storage_reliability/README.md
benchmarks/storage_reliability/INCREMENT5.md
benchmarks/storage_reliability/results/increment5-windows-profile-baseline.json
benchmarks/storage_reliability/results/increment5-windows-profiling-disabled-smoke.json
benchmarks/storage_reliability/results/increment5-windows-ab.json
benchmarks/storage_reliability/results/increment5-windows-ab.json.md
benchmarks/storage_reliability/results/increment5-linux-ab.json
benchmarks/storage_reliability/results/increment5-linux-ab.json.md
benchmarks/storage_reliability/results/increment5-windows-block4-reliability.json
benchmarks/storage_reliability/results/increment5-windows-block16-reliability.json
benchmarks/storage_reliability/results/increment5-linux-block4-reliability.json
benchmarks/storage_reliability/results/increment5-linux-block16-reliability.json
docs/VERIFICATION.md
```

Increment 5 remains unstaged and uncommitted on `feature/verified-storage-v2`.
Increment 4 is committed and pushed as `b8f2be7`. No `.vscode/` file was
modified; its preexisting untracked directory remains outside the manifest.
