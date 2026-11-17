# Storage A/B observations

Platform: windows. Warm-ups excluded; raw JSON is authoritative. OS caches uncontrolled.

| MiB | Baseline median ms | Candidate median ms | Latency change | Throughput change | Paired median latency change | Paired observation |
| ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 1 | 1199.264 | 1538.674 | 28.30% | -24.01% | -0.06% | neutral-within-5-percent |
| 16 | 5333.637 | 4492.733 | -15.77% | 18.99% | -21.10% | improvement |
| 128 | 22989.189 | 16717.858 | -27.28% | 36.48% | -17.97% | improvement |

Percentiles use nearest rank and are omitted below 20 samples. The 5% band is descriptive, not statistical significance. Production defaults are unchanged; larger blocks increase maximum recopy work.
