# 851-2315 — vnc:validate

Build `30ab375910e8+dirty` on Mac16,6. Verdict: **PASS**.

| Layer   | Result |  Time | Summary                                                                                                            |
| ------- | ------ | ----: | ------------------------------------------------------------------------------------------------------------------ |
| tests   | pass   |  22 s | packages/swift (RFB\|VNC\|ScreenSharingDiagnostics\|ScreenSharingViewerEndpoint): 318 tests; rig package: 92 tests |
| interop | pass   |  14 s | vnc:interop: PASS — 10 test(s) ran, 0 skipped                                                                      |
| bench   | pass   | 391 s | vnc-bench: no regression beyond the noise band                                                                     |
| tophat  | pass   |  26 s | vnc:tophat: PASS — 24/24 steps.                                                                                    |

## bench

Machine: Mac16,6, macOS 27.2, AC, load 3.1. Build: `30ab375910e8+dirty`.

Median of 3 run(s) per case; ± is the noise band (largest run deviation).

| scene  | profile | updates/s | input p50 ms | input p95 ms | bytes/update |    Mbit/s | CPU ms/update | copied/update |
| ------ | ------- | --------: | -----------: | -----------: | -----------: | --------: | ------------: | ------------: |
| typing | lan     |  61.6 ±2% |            – |            – |     44.3 ±0% |  0.02 ±2% |     0.52 ±12% |    103149 ±0% |
| typing | wan150  |  52.9 ±3% |            – |            – |     44.2 ±0% |  0.02 ±3% |      0.66 ±6% |    103149 ±0% |
| scroll | lan     |  60.9 ±0% |            – |            – |    40696 ±0% |  19.8 ±0% |      1.73 ±6% |   4096000 ±0% |
| scroll | wan150  |  52.5 ±2% |            – |            – |    40736 ±0% |  17.1 ±2% |      2.11 ±1% |   4096000 ±0% |
| photo  | lan     |  18.8 ±5% |            – |            – |  2923576 ±0% | 439.5 ±5% |      9.01 ±3% |   4096000 ±0% |
| photo  | wan150  |  2.14 ±0% |            – |            – |  2923587 ±0% |  50.0 ±0% |      21.6 ±4% |   4096000 ±0% |
| input  | lan     |         – |     3.30 ±1% |     3.50 ±3% |            – |         – |             – |             – |
| input  | wan150  |         – |    161.3 ±1% |    169.4 ±0% |            – |         – |             – |             – |

## Against /Users/alexandru/codevisor/c1c03091-66c4-4d69-808e-48293c61de1e/currant/tmp/vnc-bench/2026-09-23T162357Z/main/bench.json (build `main 30ab375910e8`)

| case          | metric        | baseline | current | change | verdict     |
| ------------- | ------------- | -------: | ------: | -----: | ----------- |
| input/lan     | input p50 ms  |     3.34 |    3.30 |    -1% | withinNoise |
| input/lan     | input p95 ms  |     3.72 |    3.50 |    -6% | withinNoise |
| input/wan150  | input p50 ms  |    161.2 |   161.3 |    +0% | withinNoise |
| input/wan150  | input p95 ms  |    169.2 |   169.4 |    +0% | withinNoise |
| photo/lan     | updates/s     |     18.5 |    18.8 |    +1% | withinNoise |
| photo/lan     | bytes/update  |  2923576 | 2923576 |    +0% | withinNoise |
| photo/lan     | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| photo/wan150  | updates/s     |     2.14 |    2.14 |    +0% | withinNoise |
| photo/wan150  | bytes/update  |  2923587 | 2923587 |    +0% | withinNoise |
| photo/wan150  | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/lan    | updates/s     |     61.1 |    60.9 |    -0% | withinNoise |
| scroll/lan    | bytes/update  |    40696 |   40696 |    +0% | withinNoise |
| scroll/lan    | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/wan150 | updates/s     |     50.8 |    52.5 |    +3% | withinNoise |
| scroll/wan150 | bytes/update  |    40736 |   40736 |    +0% | withinNoise |
| scroll/wan150 | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| typing/lan    | updates/s     |     61.6 |    61.6 |    -0% | withinNoise |
| typing/lan    | bytes/update  |     44.3 |    44.3 |    +0% | withinNoise |
| typing/lan    | copied/update |   103149 |  103149 |    +0% | withinNoise |
| typing/wan150 | updates/s     |     49.9 |    52.9 |    +6% | withinNoise |
| typing/wan150 | bytes/update  |     44.2 |    44.2 |    +0% | withinNoise |
| typing/wan150 | copied/update |   103149 |  103149 |    +0% | withinNoise |
