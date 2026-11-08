# FlashGuard AI — Hardware-Aware Consumer Storage Companion & Chaos MCP Harness

> A Flutter storage verification prototype with a Python MCP fault-injection harness.

![FlashGuard AI Architecture](docs/assets/flashguard_banner.svg)

![Windows audit demo showing a corrupt MP4 and exact duplicate group](docs/assets/windows_audit_demo.png)

The current demo reads a chosen directory, including the virtual-drive fixture. Native volume access remains future work. The score uses simulated free space, and throughput drops are only a thermal-throttling heuristic. A verified copy is not permission to erase the original.

## Verified Today vs. Production Roadmap

| Area | Verified today | Production roadmap |
|---|---|---|
| Storage access | Windows demo reads a chosen directory and the virtual-drive fixture. `ExternalVolumeProvider` separates capacity from the worker; mobile channel handlers explicitly report that access is pending. | Implement Android SAF document streams and persisted URI grants, iOS security-scoped bookmarks, and native volume capacity queries. A SAF URI is not a mount path. |
| Copy integrity | SHA-256 comparison, completed-block `.part` checkpoints, validated resume, re-audit of matching existing copies without retransferring, refusal to overwrite mismatched targets, and basic JPEG/MP4 structure checks. A trusted baseline hash detects a pre-existing bit flip. | Add durable write guarantees, platform stream resume, larger-media testing, and deeper media validation. |
| Duplicate detection | Exact byte duplicates grouped by SHA-256. | Decode images for perceptual similarity and add user-reviewed duplicate actions. |
| Telemetry | Per-file throughput samples and a demo score using `SimulatedVolumeProvider` free-space headroom; speed drops are a heuristic. | Query Android volume statistics where a SAF URI can be resolved, iOS `URLResourceValues`, and supported hardware telemetry; calibrate the score. |
| Verification | Python and Flutter tests cover deterministic corruption and recovery cases; CI runs both suites. | Exercise Android and Apple devices, larger media fixtures, and real disconnect scenarios. |

## Why This Matters to Sandisk's Consumer App Team

| Product outcome | Engineering mechanism | Evidence boundary |
|---|---|---|
| Fewer avoidable support cases | Surface incomplete media and failed copy checks before a user discards the source. | Prototype detects fixture faults; no support or RMA reduction has been measured. |
| More useful offline companion app | Group exact duplicates and show a local audit without uploading personal media. | Demo flow works on directories; mobile document-provider access remains pending. |
| Faster storage-feature reviews | Repeatable MCP fault injection, a PR checklist, and CI verification. | Deterministic tests pass; team velocity has not been measured. |

---

## 1. Why This Exists (The Unsolved Consumer Storage Problem)
Millions of photographers, filmmakers, and everyday consumers offload irreplaceable memories onto Sandisk portable SSDs and SD cards. Yet mobile companion apps treat external storage as an infallible, passive folder tree—leaving three critical gaps:
1. **Silent Data Corruption:** Abrupt USB-C disconnects or power drops truncate MP4/MOV `moov` atoms or JPEG EOF markers without warning, leading users to delete originals from their phones before discovering unplayable files.
2. **Thermal Cliffing Blindness:** Sustained high-bitrate transfers trigger flash controller thermal throttling without actionable diagnostics or health confidence scoring in the mobile UI.
3. **Cloud-Dependent Media Triage:** Users cannot deduplicate burst shoots or audit terabytes of private local media without uploading files to paid cloud services.

---

## 2. Holistic System Architecture

```mermaid
flowchart LR
    subgraph AI_Dev_Loop["AI-Native Verification Loop (Team Multiplier)"]
        CC["Claude Code / Cursor"] <--> MCP["flashguard-chaos MCP Server"]
        MCP --> VDrive["Virtual SSD + Injected Faults\n(Truncated MP4, Cable Yank, Burst Dups)"]
    end

    subgraph Flutter_App["Flutter Consumer Companion (Isolate-Backed)"]
        UI["Material 3 Dashboard\n(Drive Confidence Score 0-100)"] <--> ISO["Background Dart Isolate Worker"]
        ISO --> INT["IntegrityEngine\n(Streaming SHA-256 + Binary Header Forensics)"]
        ISO --> TEL["TelemetryTracker\n(Throughput Curve & Thermal Cliff Detector)"]
        ISO --> DEDUP["Exact SHA-256\nDuplicate Groups"]
    end

    VDrive --> ISO
```

---

## 3. Key Technical Highlights

* **Background batch (`Isolate.run`):** File copying, hashing, and header inspection run in a worker isolate.
* **Resumable `.part` files:** Completed blocks are flushed and recorded in `.checkpoint.json`. Resume re-hashes the source and saved blocks before reuse, then re-hashes the completed copy. The sidecar stores block digests, not a serialized SHA-256 state. A trusted original digest is required to detect corruption that predates the copy.
* **Team Force-Multiplier (`mcp-server/server.py`):** A Model Context Protocol (MCP) server and custom `/verify-storage-pr` slash command that lets any Flutter engineer on the team spin up virtual drives with simulated hardware faults before opening a PR.
* **Draft review log (`docs/AI_BLUFF_LOG.md`):** Records issues found while reviewing the supplied generated code. It does not claim benchmarks or agent runs that were not performed.

---

## 4. Quick Start & Verification

### Run the Flutter Verification Suite
```bash
cd app
flutter pub get
flutter analyze --fatal-infos
flutter test test/storage_chaos_test.dart
flutter run
```

### Run the MCP Chaos Server (Claude Code / Cursor)
```bash
cd mcp-server
pip install 'mcp>=1.0,<2'
python server.py
```

---

## 5. Engineering Thesis: AI-Native Velocity Meets Storage Rigor
> *"AI coding agents have collapsed the cost of writing boilerplate Flutter widgets to near zero. That shifts the true engineering bottleneck to **specification clarity, deterministic verification harnesses, and domain empathy**. In consumer storage, where silent data loss is unacceptable, an AI-native engineer's highest leverage comes from building automated fault-injection sandboxes that verify every line of agent-generated I/O code before it ever reaches a senior engineer's review queue."*
