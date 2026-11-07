# Generated-Code Review Log

These are findings from reviewing the supplied draft. They are not claims of
past agent runs, memory benchmarks, or a completed hardware fault campaign.

| # | Finding | Evidence in draft | Change |
|---|---|---|---|
| 1 | The MP4 fixture declared a 16-byte moov box but appended 4,096 bytes. | Original `server.py` fixture | Build boxes from payload lengths and parse top-level boundaries. |
| 2 | A search for the text `moov` could accept data embedded inside an `mdat` payload. | Original `integrity_engine.dart` and server ground truth | Walk MP4 boxes and add a misleading-payload test. |
| 3 | The transfer could replace an existing destination and did not recheck a changing source. | Original `verifiedOffload` | Refuse existing targets and compare current source and staged copy digests. |
| 4 | The UI said “SAFE TO FORMAT” after a single file audit. | Original dashboard chip | Say “COPY VERIFIED”; keep the original until independently reviewed. |
| 5 | Sampled compressed bytes were described as a perceptual hash and semantic search. | Original `perceptual_dedup.dart` and README | Label the byte fingerprint experimental and keep exact SHA-256 dedup separate. |
