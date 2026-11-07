# SPEC: FlashGuard — Hardware-Aware Consumer Storage Companion

## 1. Problem Statement
Mobile creators and everyday consumers offload gigabytes of irreplaceable photos and 4K/ProRes video onto external SSDs and SD cards. Existing mobile companion apps act as passive file browsers, leaving three critical gaps:
1. **Silent Media Corruption:** Abrupt USB-C/Lightning disconnects or thermal throttling leave truncated MP4/MOV atoms or bit-rotted files unnoticed until after the user deletes originals from their phone.
2. **Transfer & Thermal Anxiety:** Sustained writes trigger flash controller thermal throttling without clear telemetry or actionable feedback in the UI.
3. **Zero Offline Intelligence:** Users cannot search or deduplicate terabytes of private local media without uploading to paid cloud services.

## 2. Core Functional Requirements
- **F1. Streaming Copy Verification:** Copy through a stream into a temporary `.part` file, compare source and destination SHA-256 digests, then rename. Never infer that originals can be erased from this check alone.
- **F2. Binary Media Header Forensics:** Validate magic bytes and container structure before and after transfer:
  - JPEG (`FF D8` start-of-image and `FF D9` end-of-image markers).
  - MP4/MOV (valid `ftyp` and `moov` box headers; flag missing `moov` atoms caused by interrupted recording/transfers).
- **F3. Demo Confidence Score (0–100):** Combine verified-file ratio, throughput-drop heuristic, and simulated free-space headroom. A real free-space probe and temperature measurement remain future work.
- **F4. Offline Deduplication:** Group exact duplicates by SHA-256. The structural byte fingerprint in `perceptual_dedup.dart` is experimental and is not a decoded-image perceptual hash or semantic search.

## 3. Non-Functional & Safety Invariants
- **Source Preservation:** This app never deletes source files and refuses to overwrite an existing destination.
- **UI Responsiveness:** Batch file I/O runs inside a Dart isolate. Frame rate has not been benchmarked.
