# Storage A/B observations

Platform: linux. Warm-ups excluded; raw JSON is authoritative. OS caches uncontrolled.

| MiB | Baseline median ms | Candidate median ms | Latency change | Throughput change | Paired median latency change | Paired observation |
| ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 1 | 970.433 | 964.247 | -0.64% | 1.22% | -3.72% | neutral-within-5-percent |
| 16 | 3967.589 | 3445.992 | -13.15% | 15.31% | -6.13% | improvement |
| 128 | 31533.759 | 21587.491 | -31.54% | 46.07% | -34.23% | improvement |

Percentiles use nearest rank and are omitted below 20 samples. The 5% band is descriptive, not statistical significance. Production defaults are unchanged; larger blocks increase maximum recopy work.
