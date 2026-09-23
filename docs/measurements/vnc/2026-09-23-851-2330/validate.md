# 851-2330 — vnc:validate

Build `6b518b74d7f1+dirty` on Mac16,6. Verdict: **PASS**.

| Layer   | Result |  Time | Summary                                                                                                            |
| ------- | ------ | ----: | ------------------------------------------------------------------------------------------------------------------ |
| tests   | pass   |  23 s | packages/swift (RFB\|VNC\|ScreenSharingDiagnostics\|ScreenSharingViewerEndpoint): 321 tests; rig package: 92 tests |
| interop | pass   |  15 s | vnc:interop: PASS — 10 test(s) ran, 0 skipped                                                                      |
| bench   | pass   | 400 s | vnc-bench: no regression beyond the noise band                                                                     |
| tophat  | pass   |  27 s | vnc:tophat: PASS — 24/24 steps.                                                                                    |

## bench

Machine: Mac16,6, macOS 27.2, AC, load 3.7. Build: `6b518b74d7f1+dirty`.

Median of 3 run(s) per case; ± is the noise band (largest run deviation).

| scene  | profile | updates/s | input p50 ms | input p95 ms | bytes/update |    Mbit/s | CPU ms/update | copied/update |
| ------ | ------- | --------: | -----------: | -----------: | -----------: | --------: | ------------: | ------------: |
| typing | lan     |  61.9 ±1% |            – |            – |     44.3 ±0% |  0.02 ±1% |     0.55 ±27% |    103149 ±0% |
| typing | wan150  |  53.6 ±2% |            – |            – |     44.2 ±0% |  0.02 ±2% |      0.67 ±7% |    103149 ±0% |
| scroll | lan     |  61.5 ±1% |            – |            – |    40696 ±0% |  20.0 ±1% |     1.79 ±34% |   4096000 ±0% |
| scroll | wan150  |  53.2 ±1% |            – |            – |    40736 ±0% |  17.4 ±1% |     2.04 ±64% |   4096000 ±0% |
| photo  | lan     |  18.7 ±0% |            – |            – |  2923576 ±0% | 436.5 ±0% |      8.96 ±1% |   4096000 ±0% |
| photo  | wan150  |  2.14 ±0% |            – |            – |  2923587 ±0% |  50.0 ±0% |      21.8 ±4% |   4096000 ±0% |
| input  | lan     |         – |     3.40 ±3% |    3.59 ±10% |            – |         – |             – |             – |
| input  | wan150  |         – |    155.2 ±1% |    163.5 ±1% |            – |         – |             – |             – |

## Against /Users/alexandru/codevisor/c1c03091-66c4-4d69-808e-48293c61de1e/currant/tmp/vnc-bench/2026-09-23T174724Z/main/bench.json (build `main 6b518b74d7f1`)

| case          | metric        | baseline | current | change | verdict     |
| ------------- | ------------- | -------: | ------: | -----: | ----------- |
| input/lan     | input p50 ms  |     3.36 |    3.40 |    +1% | withinNoise |
| input/lan     | input p95 ms  |     3.46 |    3.59 |    +4% | withinNoise |
| input/wan150  | input p50 ms  |    155.8 |   155.2 |    -0% | withinNoise |
| input/wan150  | input p95 ms  |    164.1 |   163.5 |    -0% | withinNoise |
| photo/lan     | updates/s     |     18.8 |    18.7 |    -1% | withinNoise |
| photo/lan     | bytes/update  |  2923576 | 2923576 |    +0% | withinNoise |
| photo/lan     | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| photo/wan150  | updates/s     |     2.14 |    2.14 |    -0% | withinNoise |
| photo/wan150  | bytes/update  |  2923587 | 2923587 |    +0% | withinNoise |
| photo/wan150  | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/lan    | updates/s     |     61.4 |    61.5 |    +0% | withinNoise |
| scroll/lan    | bytes/update  |    40696 |   40696 |    +0% | withinNoise |
| scroll/lan    | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/wan150 | updates/s     |     52.4 |    53.2 |    +2% | withinNoise |
| scroll/wan150 | bytes/update  |    40736 |   40736 |    +0% | withinNoise |
| scroll/wan150 | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| typing/lan    | updates/s     |     62.3 |    61.9 |    -1% | withinNoise |
| typing/lan    | bytes/update  |     44.3 |    44.3 |    +0% | withinNoise |
| typing/lan    | copied/update |   103149 |  103149 |    +0% | withinNoise |
| typing/wan150 | updates/s     |     53.0 |    53.6 |    +1% | withinNoise |
| typing/wan150 | bytes/update  |     44.2 |    44.2 |    +0% | withinNoise |
| typing/wan150 | copied/update |   103149 |  103149 |    +0% | withinNoise |
