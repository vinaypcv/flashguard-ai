# FlashGuard real-filesystem reliability harness

Run from the repository root after `flutter pub get` in `app`. The entry point
uses a real Dart VM child process and imports the production `IntegrityEngine`
and `NativeAtomicFilePromoter`. It does not replace the copy or promotion code.

## Commands

Windows PowerShell (repository SDK):

```powershell
.\.tools\flutter\bin\dart.bat --packages=app/.dart_tool/package_config.json benchmarks/storage_reliability/run.dart --suite=reliability --rounds=5 --output=benchmarks/storage_reliability/results/windows-reliability.json
.\.tools\flutter\bin\dart.bat --packages=app/.dart_tool/package_config.json benchmarks/storage_reliability/run.dart --suite=benchmark --sizes-mib=1,16,128 --samples=10 --output=benchmarks/storage_reliability/results/windows-benchmarks.json
```

Linux with Dart on PATH (including CI):

```sh
dart --packages=app/.dart_tool/package_config.json benchmarks/storage_reliability/run.dart --suite=reliability --rounds=5 --output=benchmarks/storage_reliability/results/linux-reliability.json
dart --packages=app/.dart_tool/package_config.json benchmarks/storage_reliability/run.dart --suite=benchmark --sizes-mib=1,16,128 --samples=10 --output=benchmarks/storage_reliability/results/linux-benchmarks.json
```

`--suite=all` runs both suites. `--suite=smoke` measures only 1 MiB, with one
warm-up and two measured copies plus one interrupted/restarted transfer.
`--seed=5904128` is the default. `--samples` accepts 1â€“30, `--rounds` accepts
1â€“25. `--sizes-mib` accepts 1,16,128 and optionally 1024 (explicitly requested).
Normal benchmarks preserve a 1 GiB free-space margin and keep at most one
source and one destination for the current size. Generation and fixture hashing
occur before measured transfer intervals. Failed experiment roots are
retained and identified in JSON for inspection; per-sample benchmark scratch
destinations may already have been cleaned. Successful roots are removed.
Exit code 1 means at least one failed record; 0 can include explicit
skips. Inspect the summary and each skipped reason.

## Process termination and concurrent writers

The controller launches this same entry point with an internal `--worker` flag.
Configuration is the first stdin JSON line; stdout is a JSON-lines event stream.
A worker emits `ready` with its PID, stage, offset, metrics and transition
history, flushes stdout, and waits for `continue` on stdin. The controller either
releases the gate or terminates the process and waits for a nonzero exit.
There are timeouts to detect a stuck test, and no timing sleeps authorize kills.

The five kill stages are:

| Stage | What has happened when termination is requested |
| --- | --- |
| `blockFlushed` | First part block written and flushed; no checkpoint yet |
| `checkpointSaved` | First v2 checkpoint staged and promoted |
| `verificationBlockRead` | Whole-file verification has opened/read its first part chunk; stream suspended before feeding that chunk into SHA-256 |
| `promotionStarted` | Data verified and native sync requests completed; atomic move not yet called |
| `promoted` | Native move returned successfully; post-promotion verification/cleanup not yet run |

These are synchronized operation boundaries, not random kills in the middle of
a native syscall. SIGKILL is used on Linux; Dart's `Process.kill` uses native
process termination on Windows. No worker exception handler or `finally` block
is relied upon to release a killed process's native lease. Restart verifies the
source and final digest, bounded checkpoint metadata, expected reuse offset,
and successful reacquisition of the OS lock. An uncheckpointed block must be
recopied; an already promoted file must be rehashed and reused.

Native races use two independent PIDs with different part files, both held at
a promotion gate. Releasing both demonstrates native no-replace protection:
exactly one wins, the loser reports a conflict and retains its original part,
and final content matches the winner. A separate occupied-target case requires
both writers to fail and preserve existing contents. The workspace experiment
uses the full engine: one process holds a checkpoint/lease, another is refused,
the owner is killed, and a fresh process must acquire the same lock inode.
Changed source identity must invalidate the old journal; retry with conflicting
contents must select the numbered filename. This distinguishes cooperation via
the workspace lock from independent native no-replace protection.

## Real disk-full opt-in

**Disabled by default. Do not use your ordinary system or data volume.**
The default artifact records `status: skipped` and `realEnospcObserved: false`.
The harness never creates/mounts/formats a volume or grants itself privileges.

Supported targets are a separately created, tiny disposable Windows volume
labelled **FLASHGUARD_DISPOSABLE** on a drive other than C: or the system drive,
or a dedicated Linux `tmpfs` mount whose mount path contains
`/flashguard-disposable-`. Shared `/tmp` and `/dev/shm` do not qualify. Use a
child directory of the volume; filesystem roots are rejected. Keep the volume
at 64 or 128 MiB; its entire capacity must fit within the allocation budget
minus a 16 MiB reserve. This intentionally excludes normal large user disks and
generic unverified quota configurations.

Inside your approved child directory, create `.flashguard-disposable.json`:

```json
{
  "purpose": "flashguard-real-enospc",
  "disposable": true,
  "approvedDirectory": "Z:\\approved",
  "maxAllocationBytes": 268435456
}
```

On Linux, use the exact canonical child path instead of `Z:\approved`. After
independently checking the disposable mount, pass all three explicit controls:

```powershell
.\.tools\flutter\bin\dart.bat --packages=app/.dart_tool/package_config.json benchmarks/storage_reliability/run.dart --suite=reliability --enable-disk-full --disk-full-path=Z:\approved --approve-disk-full-path=Z:\approved --max-allocation-mib=256 --output=benchmarks/storage_reliability/results/disposable-enospc.json
```

The controller pauses the engine after its first checkpoint, allocates a
private non-sparse filler in 64 KiB writes, and caps allocation. It requires a
real OS disk-full error from both filler and resumed production transfer,
asserts no final file was committed, removes only its own filler, and starts
a fresh engine worker. Success requires matching source/final SHA-256. Reaching
the allocation cap without ENOSPC is a skip, never a successful real-disk-full
claim. POSIX ENOSPC/EDQUOT and Windows DISK_FULL/HANDLE_DISK_FULL codes are
recognized; other failures fail the experiment.

Cleanup removes only the newly created `flashguard_enospc_*` subdirectory.
If the controller itself is forcibly stopped, inspect the exact retained path
before deleting its `filler.bin` to free space; then rerun recovery. Preserve
the part/checkpoint until recovery is checked. Unmount/detach the disposable
volume using your normal platform tools after testing. Never point cleanup at
the approved parent or delete unrelated files. Shared hosted CI never opts in.

## Measurements and schema (version 2; legacy artifacts retain version 1)

Each artifact is a JSON object with these fields:

| Field | Meaning |
| --- | --- |
| `schemaVersion` | Integer 2 for new runs; historical artifacts retain 1 |
| `startedUtc`, `completedUtc` | Actual UTC timestamps |
| `options` | Suite, seed, samples, sizes, allocation limit, opt-in |
| `environment` | OS/kernel, Dart, filesystem/mount/free space, capabilities, base Git SHA and source file hashes; dirty code is explicitly recorded |
| `summary` | Counts of passed, failed, skipped experiment records |
| `workspace`, `workspaceRetained` | Private fixture root and whether failures left evidence there |
| `records` | Array of experiments, each with kind, ID, seed, status and type-specific evidence |

`processKill` records include the gate, actual forced exit code, checkpoint
snapshot, fresh-worker audit, and recovery outcome. `nativeProcessRace` records
include distinct PIDs, each writer's result, and final digest. A failed record
contains its seed, stage/ID, error/stack, and recovery outcome; the enclosing
environment supplies the platform and filesystem needed to reproduce it.
Completed or skipped `diskFull` records state whether a real ENOSPC error was
observed. A failed opt-in run carries its failure diagnostics and establishes
no successful exhaustion/recovery claim.

`benchmark` records contain fixture size/digest/preparation time, an excluded
warm-up, raw measured `samples`, summaries, and a killed/restarted `resume` run.
Every sample includes engine `endToEndMicros`, overall `endToEndMiBs`, and
`copyCheckpointMiBs`. Controller latency additionally includes VM startup/exit
and IPC. Diagnostics separate source hash, checkpoint validation, copy plus
checkpoint writes, pre-promotion verification, and post-promotion verification.
`resumedBytes` and `transferredBytes` come from the production audit; logical
data and UTF-8 checkpoint bytes count completed writes only. Their ratio to
source bytes is **logical** write amplification, excluding lock files, failed
partial writes, directory metadata and storage-device writes. Physical write
amplification is null because no device counters are collected.

For a kill record, bytes copied again after an interruption can be derived as
`max(0, checkpointReady.metrics.copyBytesWritten - recovery.resumedBytes)`;
use zero when `recovery.reusedExistingCopy` is true. The uncheckpointed-block
experiment recopies 256 KiB. All recovery-worker transmission, including the
previously unwritten tail, is `recovery.transferredBytes`. Benchmark resumes
stop at saved checkpoints, so they reuse that full offset without recopying a
previously written prefix. Combining the gate's completed-write counters with
the resume worker's counters gives the interrupted experiment's total logical
writes, distinct from either worker's per-attempt ratio.

Process CPU microseconds use Windows `GetProcessTimes` or Linux `/proc/self/stat`
with `CLK_TCK`; RSS and peak RSS come from Dart's `ProcessInfo`. Measurements
include worker instrumentation overhead and have OS-dependent resolution.
Median is computed from raw samples. p95 is null below 20 samples, rather than
implying percentile confidence from a few runs. Timings are never hard-coded.

Copies always use a fresh destination, but OS caches are **not evicted**.
Consequently these are new-destination copy measurements, not controlled cold
device-cache benchmarks. Each sample is a fresh JIT VM; warm-up primes filesystem
caches, not a persistent worker's JIT. Repeated fixture blocks can interact with
compression/deduplication. No power-loss, hardware-disconnect, production-scale
thermal, or independent-device write-amplification guarantee follows.

## CI and local Linux execution

Separate Windows/Linux native-process jobs upload JSON artifacts even on a
failed experiment. A bounded 1 MiB performance job is independent of the full
Flutter/MCP regressions. Workflow presence does not establish Linux execution;
inspect the actual JSON OS, kernel, filesystem, capabilities and record results.
WSL Linux evidence, if supplied, is identified as WSL and does not represent
bare-metal Linux or physical crash testing.

Published artifacts replace machine-specific repository and temporary roots
with `<WORKSPACE>` and `<RUN_WORKSPACE>`. `pathRedactions` records this step and
the original artifact's SHA-256. Numeric measurements, seeds, transition
histories, data hashes and source hashes are preserved. Private originals may
be retained under ignored `.tools/`; these redactions do not describe filesystem
paths that were literally used during execution.

For this Windows workspace, a local Linux SDK and translated package paths can
be kept under ignored `.tools/`. The recorded WSL command uses those paths;
ordinary Linux/CI should resolve dependencies natively in `app` instead.

## Increment 5 phase profiling and A/B comparisons

See [INCREMENT5.md](INCREMENT5.md) for the measured candidate-selection basis
and complete experiment protocol. The current experiment compares 4 MiB
baseline checkpoint blocks with opt-in 16 MiB blocks. The production default
remains 4 MiB. Every block is flushed and checkpointed with the existing
protocol; all source checks, byte verification, native sync and atomic
promotion remain mandatory. The larger maximum recopy tail and read buffer
are explicit tradeoffs.

Use the same entry point with these arguments:

```text
--suite=ab --sizes-mib=1,16,128 --samples=10 --baseline-block-mib=4 --candidate-block-mib=16 --output=benchmarks/storage_reliability/results/increment5-windows-ab.json
```

Run on Linux separately and use increment5-linux-ab.json as the output.
The embedded Windows executable can also be invoked directly as
.tools/flutter/bin/cache/dart-sdk/bin/dart.exe. Both variants receive one
excluded warm-up and at least ten matched pairs. Pair order alternates and
the seed controls which variant runs first. The artifact preserves each raw
sample, variant, pair index, sequence, process ID, block size and phase ledger.
A sibling .json.md file contains the generated before/after summary.
Baseline/candidate distributions include median, minimum and maximum.
p95 is omitted below 20 samples per configuration; otherwise it uses nearest
rank. The descriptive 5% paired-latency band is not a significance test.
Negative and neutral observations are retained.

The default normal benchmark repetition count is now ten. A/B rejects fewer
than ten pairs. Legacy explicit smaller normal benchmark counts and the
bounded two-sample smoke suite remain supported for diagnostics, not for
claims about this A/B experiment.

Use --block-mib=4 or --block-mib=16 with --suite=reliability to exercise each
configuration. Larger-block fixtures contain at least two blocks. A changed
checkpoint block size rejects incompatible journal metadata and restarts
safely. Use --profiling=false to disable phase collection; engine callers
can omit diagnostics or pass TransferDiagnostics(enabled:false).
When profiling is disabled, logicalWriteAmplification is null because logical
write counts were not collected. Zeroed disabled counters are not measurements.

Schema 2 adds exclusive per-phase timings, operation counts and observable
read/write bytes under metrics.phases. It records blockBytes,
checkpointCount, resumedBytes, nativeFileSyncCount, directorySyncCount and
totalMicros. The phases separate setup, initial hash, checkpoint validation,
source reads, block writes, data flushes, block hashes, JSON serialization,
checkpoint persistence, temporary verification, source consistency,
media inspection, durability, promotion, final verification, reuse and cleanup.
Legacy aggregate fields overlap these phases and must not be added again.
accountedMicros and unattributedMicros expose coverage of the total.
Counters exclude filesystem/device metadata, stat calls, media-header bytes
and any unknown partial writes. Stream counters count chunks delivered to the
consumer; OS read-ahead and device traffic are not observed. Failed operations
can leave incomplete counters and timing coverage. Use a fresh diagnostics
instance per attempt.

CI process-recovery jobs now test both block sizes on Windows and Linux.
The long local A/B runs are separate from the bounded CI smoke check.
