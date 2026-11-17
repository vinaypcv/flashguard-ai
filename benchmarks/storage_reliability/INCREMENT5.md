# Increment 5: profiling and controlled optimization

## Candidate decision before A/B execution (2026-11-17)

The instrumented Windows NTFS baseline used one warm-up and ten measured
128 MiB transfers at 4 MiB per checkpoint block. Median engine latency was
19.463428 seconds. Raw data: results/increment5-windows-profile-baseline.json.

| Phase | Median share | Operations |
| --- | ---: | ---: |
| Part-file flush | 24.97% | 33 |
| Checkpoint persistence, including journal flush/rotation | 13.02% | 32 |
| Block SHA-256 | 12.94% | 32 |
| Initial source hash | 9.26% | 1 |
| Temporary verification | 8.84% | 1 |
| Source consistency | 8.62% | 1 |
| Final file/source verification | 17.70% | 1 group |
| Native durability | 2.86% | 1 group |
| Source reads | 0.51% | 32 |
| JSON serialization/checksum encoding | 0.04% | 32 |

These are medians of sample ratios, not an additive decomposition of medians.
The raw ledger also records setup, writes, validation, media inspection,
promotion, cleanup and unattributed overhead.

Selected experiment: baseline 4 MiB blocks versus opt-in 16 MiB blocks. At
128 MiB this reduces copy/checkpoint iterations from 32 to 8. Data is still
flushed before every checkpoint. Trusted digests, source checks, pre/post
verification, native sync and atomic no-replace promotion remain required.
Production defaults remain at 4 MiB.

Tradeoffs: maximum uncheckpointed recopy work grows from one 4 MiB block to
one 16 MiB block, and the read buffer is larger. Incompatible checkpoint block
sizes are rejected and the part restarts; the source is preserved. Matching
checkpoints still require metadata and all referenced-block validation.
Buffer reuse and JSON allocation changes are deferred, not benchmarked as
candidates: measured reads/serialization are small in this baseline. Skipping
required checks or flushes was not attempted.

## Controlled protocol

Use one excluded warm-up per variant and ten measured matched pairs at each
of 1, 16 and 128 MiB. Reverse pair order on alternate iterations; the seed
controls the first position. Use the same fixture, fresh destinations, fresh
JIT workers and enabled profiling for both variants. Windows NTFS and WSL2
ext4 run separately and are not equivalent physical-storage environments.
OS caches are uncontrolled.

Preserve raw samples, order, configuration, PIDs and phase ledgers. Report
median, minimum and maximum. p95 uses nearest rank (ceil(0.95*n)-1 in a
zero-based sorted array) only with at least 20 samples per configuration;
with ten it is null. Paired latency changes are retained. The descriptive
plus/minus 5% band is not statistical significance. Positive latency change
means slower. Neutral and negative outcomes remain in the report.

Phase ledgers are exclusive. Legacy aggregate fields overlap phases and must
not be added again. Unattributed time includes orchestration and observations.
Byte counters cover observed completed I/O, not device traffic or stat/header
reads. Failed operations can leave incomplete counts. Use a fresh diagnostics
instance per attempt. Omit diagnostics or use enabled:false to disable them;
the CLI also accepts --profiling=false. A/B keeps profiling enabled for both.
Published output redacts location strings without changing measured numbers.

## Commands

Use the existing runner with --packages=app/.dart_tool/package_config.json.

- Baseline trace: --suite=benchmark --sizes-mib=128 --samples=10 --block-mib=4
- A/B: --suite=ab --sizes-mib=1,16,128 --samples=10 --baseline-block-mib=4 --candidate-block-mib=16
- Output: --output=benchmarks/storage_reliability/results/increment5-windows-ab.json
- Linux: the same arguments, with increment5-linux-ab.json as output.
- Reliability: --suite=reliability --block-mib=4 and --block-mib=16 on each platform.

The embedded Windows executable is .tools/flutter/bin/cache/dart-sdk/bin/dart.exe.
The local WSL setup uses .tools/linux-dart/dart-sdk/bin/dart with
.tools/linux-package-config.json. Larger-block kill fixtures contain at least
two blocks. Run all Flutter/MCP regressions. Disk exhaustion stays disabled.


## Observed A/B results (2026-11-17)

Both runs used seed `5904128`, ten measured pairs per size, and one excluded
warm-up per variant. There are **120 measured transfers** across both platforms.
All returned a committed byte-verified audit and passed the controller's
independent source/final digest checks. Each A/B artifact reports three passing
size experiments, zero failures, and an explicit disk-full skip.

Windows: x64 Windows 11 build 26300, local NTFS, Dart 3.13.7.
Linux: Ubuntu 24.04 in WSL2, kernel
`6.18.33.1-microsoft-standard-WSL2`, ext4 on `/dev/sdd`, Dart 3.13.7.
Fixtures were on NTFS / WSL ext4 respectively; Linux did not copy onto the
Windows repository mount. Runs were sequential by platform. The subsequent
correctness runs could overlap; their latency is not benchmark evidence.

| Platform | MiB | Baseline median s | Candidate median s | Baseline MiB/s | Candidate MiB/s | Latency change | Throughput change | Paired latency change | Faster pairs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Windows NTFS | 1 | 1.199264 | 1.538674 | 0.8586 | 0.6525 | 28.30% | -24.01% | -0.06% | 5/10 |
| Windows NTFS | 16 | 5.333637 | 4.492732 | 3.0130 | 3.5851 | -15.77% | 18.99% | -21.10% | 7/10 |
| Windows NTFS | 128 | 22.989189 | 16.717858 | 5.6099 | 7.6565 | -27.28% | 36.48% | -17.97% | 9/10 |
| WSL2 ext4 | 1 | 0.970433 | 0.964248 | 1.0325 | 1.0451 | -0.64% | 1.22% | -3.72% | 6/10 |
| WSL2 ext4 | 16 | 3.967589 | 3.445991 | 4.0368 | 4.6547 | -13.15% | 15.31% | -6.13% | 6/10 |
| WSL2 ext4 | 128 | 31.533759 | 21.587491 | 4.0594 | 5.9295 | -31.54% | 46.07% | -34.23% | 10/10 |

Latency change compares the two distribution medians; paired change is the
median of ten within-pair percentage changes. Throughput is the median of
sample throughputs, so it need not equal size divided by median latency.
Negative latency change means faster. These statistics describe this run,
without a confidence interval or a causal claim about all storage devices.

| Platform | MiB | Baseline min / max seconds | Candidate min / max seconds |
| --- | ---: | ---: | ---: |
| Windows NTFS | 1 | 0.723472 / 10.050930 | 0.702254 / 2.085994 |
| Windows NTFS | 16 | 2.698861 / 25.985391 | 2.044883 / 15.212540 |
| Windows NTFS | 128 | 18.901492 / 56.656207 | 15.583944 / 109.892472 |
| WSL2 ext4 | 1 | 0.711243 / 7.538088 | 0.709227 / 4.705737 |
| WSL2 ext4 | 16 | 3.258680 / 5.629051 | 2.173983 / 5.475143 |
| WSL2 ext4 | 128 | 29.041220 / 77.139032 | 18.297046 / 27.486334 |

All outliers remain in the JSON. The 128 MiB Windows candidate maximum was
109.892472 s, versus 56.656207 s for baseline. That candidate sample included
23.975 s flushing, 11.496 s journal persistence, 41.907 s source-consistency
hashing, and 26.035 s final verification. The measurements do not establish a
single cause. The 1 MiB Windows distribution median regressed 28.30%, while
its paired median was effectively neutral (-0.06%, 5/10 pairs faster).
Both block settings need one block at 1 MiB, so no reduction in checkpoint
iterations is expected. WSL's 1 MiB paired result is also within the descriptive
neutral band. No tail-latency or universal improvement is claimed.

### Phase breakdown at 128 MiB

Each entry below is median seconds / median percentage of engine total.
Medians of separate phases or ratios are not additive decompositions of the
median total. Full per-phase distributions and all raw counters are in JSON.

| Phase | Windows baseline | Windows candidate | WSL baseline | WSL candidate |
| --- | ---: | ---: | ---: | ---: |
| setup | 0.0223 / 0.11% | 0.0217 / 0.13% | 0.0179 / 0.06% | 0.0175 / 0.08% |
| sourceHash | 1.8596 / 8.21% | 1.8337 / 11.09% | 1.9392 / 6.18% | 1.9699 / 9.36% |
| checkpointValidation | 0.0025 / 0.01% | 0.0026 / 0.02% | 0.0018 / 0.01% | 0.0017 / 0.01% |
| sourceRead | 0.1130 / 0.46% | 0.0887 / 0.51% | 0.1561 / 0.49% | 0.0992 / 0.45% |
| blockWrite | 0.1352 / 0.55% | 0.1120 / 0.61% | 0.3036 / 0.91% | 0.1801 / 0.84% |
| dataFlush | 6.4845 / 27.12% | 4.1973 / 24.30% | 13.2902 / 41.02% | 6.5925 / 28.42% |
| blockHash | 2.5187 / 11.05% | 1.8534 / 11.19% | 2.5216 / 8.20% | 1.9022 / 8.98% |
| checkpointSerialization | 0.0090 / 0.04% | 0.0047 / 0.03% | 0.0110 / 0.04% | 0.0059 / 0.03% |
| checkpointPersistence | 4.1691 / 18.44% | 1.0583 / 6.35% | 5.9117 / 19.22% | 2.4915 / 11.46% |
| tempVerification | 1.7104 / 7.91% | 1.7461 / 10.45% | 1.8143 / 5.70% | 1.8123 / 8.53% |
| sourceConsistency | 1.7103 / 7.65% | 1.7563 / 10.56% | 1.7654 / 5.57% | 1.8009 / 8.37% |
| mediaInspection | 0.0011 / 0.00% | 0.0011 / 0.01% | 0.0010 / 0.00% | 0.0011 / 0.01% |
| durability | 0.4203 / 1.61% | 0.0643 / 0.27% | 0.5963 / 1.95% | 1.2246 / 5.54% |
| promotion | 0.0200 / 0.05% | 0.0109 / 0.05% | 0.0101 / 0.03% | 0.0060 / 0.03% |
| finalVerification | 3.4288 / 17.41% | 3.4866 / 21.61% | 3.5549 / 11.38% | 3.6642 / 16.93% |
| cleanup | 0.0024 / 0.01% | 0.0027 / 0.02% | 0.0018 / 0.01% | 0.0018 / 0.01% |

The selected change reduces 128 MiB checkpoint operations from 32 to 8 and
part flushes from 33 to 9. Mandatory whole-file hash byte counts remain
unchanged: source hash N, temp verification N, source consistency N, and final
verification 2N (destination plus source), in addition to copy reads N.
Native file-sync requests remain three for these multi-block transfers;
directory sync requests remain two on Linux and unavailable on Windows.

Median journal bytes written per 128 MiB attempt decreased from 47,502 to 5,447
on Windows and 46,318 to 5,151 on WSL. Snapshot metadata still grows with block
count; no new serialization algorithm was introduced. Peak per-worker RSS
medians were 270.74 / 270.78 MiB on Windows and 253.16 / 253.36 MiB on WSL
(baseline / candidate). These process observations do not isolate allocation
or GC costs, or prove that larger buffers have no memory cost.

### Decision

Keep the **4 MiB production default**. Retain 16 MiB as an explicit experiment
through the existing block-size configuration. Larger files showed useful
median throughput improvements, but small-file variability, the Windows
outlier, larger buffers and the fourfold maximum recopy tail do not justify
a universal default change. None of the exploratory Windows median throughput
targets (1, 5, and 8 MiB/s) was met by the candidate: observed medians were
0.6525, 3.5851, and 7.6565 MiB/s.

No correctness regression was observed in executed checks. Buffer reuse,
metadata-allocation changes and alternative checkpoint-frequency policies
remain deferred; they have no A/B gain claim. Required verification, flush,
sync and no-replace operations remain in place.

### Reproduce from the repository root

Windows PowerShell, using the pinned SDK directly:

```powershell
$dart = ".\.tools\flutter\bin\cache\dart-sdk\bin\dart.exe"
& $dart --packages=app/.dart_tool/package_config.json benchmarks/storage_reliability/run.dart --suite=benchmark --sizes-mib=128 --samples=10 --block-mib=4 --output=benchmarks/storage_reliability/results/increment5-windows-profile-baseline.json
& $dart --packages=app/.dart_tool/package_config.json benchmarks/storage_reliability/run.dart --suite=ab --sizes-mib=1,16,128 --samples=10 --baseline-block-mib=4 --candidate-block-mib=16 --output=benchmarks/storage_reliability/results/increment5-windows-ab.json
& $dart --packages=app/.dart_tool/package_config.json benchmarks/storage_reliability/run.dart --suite=reliability --rounds=5 --block-mib=4 --output=benchmarks/storage_reliability/results/increment5-windows-block4-reliability.json
& $dart --packages=app/.dart_tool/package_config.json benchmarks/storage_reliability/run.dart --suite=reliability --rounds=5 --block-mib=16 --output=benchmarks/storage_reliability/results/increment5-windows-block16-reliability.json
```

For the executed WSL setup, set `$repoWslPath` to the Linux translation of the
repository path. A Linux SDK and package config were prepared in ignored
`.tools/`; ordinary Linux/CI should resolve packages natively in `app`.

```powershell
wsl -d Ubuntu-24.04 --cd "$repoWslPath" --exec "$repoWslPath/.tools/linux-dart/dart-sdk/bin/dart" "--packages=$repoWslPath/.tools/linux-package-config.json" benchmarks/storage_reliability/run.dart --suite=ab --sizes-mib=1,16,128 --samples=10 --baseline-block-mib=4 --candidate-block-mib=16 --output=benchmarks/storage_reliability/results/increment5-linux-ab.json
wsl -d Ubuntu-24.04 --cd "$repoWslPath" --exec "$repoWslPath/.tools/linux-dart/dart-sdk/bin/dart" "--packages=$repoWslPath/.tools/linux-package-config.json" benchmarks/storage_reliability/run.dart --suite=reliability --rounds=5 --block-mib=4 --output=benchmarks/storage_reliability/results/increment5-linux-block4-reliability.json
wsl -d Ubuntu-24.04 --cd "$repoWslPath" --exec "$repoWslPath/.tools/linux-dart/dart-sdk/bin/dart" "--packages=$repoWslPath/.tools/linux-package-config.json" benchmarks/storage_reliability/run.dart --suite=reliability --rounds=5 --block-mib=16 --output=benchmarks/storage_reliability/results/increment5-linux-block16-reliability.json
```

### Evidence and verification

Raw artifacts under `results/` have the `increment5-` prefix. The A/B JSON
retains collection-time source hashes. Afterwards, the Markdown renderer's
labels were clarified to display paired-median change explicitly; no collected
numeric values or production transfer code changed. A subsequent worker-only
reporting fix returns null for unavailable logical write amplification when
profiling is disabled; enabled benchmark measurements are unaffected. The
sibling `.json.md` files were regenerated from the original JSON.

A read-only audit of all 120 samples checked committed state, expected fixture
digest, fresh-copy byte counts, all whole-file hash byte counts, checkpoint and
flush operation counts, native sync counts, and nonnegative unaccounted time.
All passed. This is additional consistency checking of evidence, not a formal
proof of crash safety.


- Full Flutter suite: **47/47 passed in 2:45**, including all 43 existing tests
  and all 100 seeded recovery scenarios.
- MCP fixtures: **3/3 passed in 0.473 s**.
- Windows 4 / 16 MiB: **12 passed, 0 failed, 1 explicit ENOSPC skip each**.
- WSL2 ext4 4 / 16 MiB: **12 passed, 0 failed, 1 explicit ENOSPC skip each**.
- These four runs comprise 20 forced process-kill/restart experiments,
  20 independent empty-target races, four occupied-target races, and four
  workspace exclusion/kill/restart experiments.
- Final formatting: **26 files, 0 changed**. `git diff --check`: exit 0
  (line-ending warnings only). Staging area empty.
- Static analysis after the reporting follow-up: **no issues**, --fatal-infos.


Profiling tests compare enabled/disabled checkpoint strings and output bytes,
check phase counters, reject incompatible block-size checkpoints with safe
restart, validate A/B pairing/statistics and report labels, and verify artifact
path redaction. All 100 original recovery seeds `0x5a1700` through
`0x5a1763` remain in the full suite.


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

Real ENOSPC remains explicitly skipped because no approved disposable volume
was supplied. Remote CI for the new matrix has not run. WSL is not bare-metal
Linux. Physical power loss, device disconnect and Windows directory durability
remain unproven. API sync completion and forced process termination do not
establish physical crash consistency. The namespace-stability assumptions in
`docs/VERIFICATION.md` continue to apply.

Increment 4 was preserved and pushed as `b8f2be7`. Increment 5 remains
uncommitted and unstaged on `feature/verified-storage-v2`; the preexisting
`.vscode/` directory was not changed.
