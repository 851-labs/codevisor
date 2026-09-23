# 851-2317 — vnc:validate

Build `200a6de6facb+dirty` on Mac16,6. Verdict: **PASS**.

| Layer   | Result |  Time | Summary                                                                                                            |
| ------- | ------ | ----: | ------------------------------------------------------------------------------------------------------------------ |
| tests   | pass   |  25 s | packages/swift (RFB\|VNC\|ScreenSharingDiagnostics\|ScreenSharingViewerEndpoint): 317 tests; rig package: 92 tests |
| interop | pass   |  14 s | vnc:interop: PASS — 10 test(s) ran, 0 skipped                                                                      |
| bench   | pass   | 405 s | vnc-bench: no regression beyond the noise band                                                                     |
| tophat  | pass   |  26 s | vnc:tophat: PASS — 24/24 steps.                                                                                    |

## bench

Machine: Mac16,6, macOS 27.2, AC, load 3.1. Build: `200a6de6facb+dirty`.

Median of 3 run(s) per case; ± is the noise band (largest run deviation).

| scene  | profile | updates/s | input p50 ms | input p95 ms | bytes/update |    Mbit/s | CPU ms/update | copied/update |
| ------ | ------- | --------: | -----------: | -----------: | -----------: | --------: | ------------: | ------------: |
| typing | lan     |  61.7 ±0% |            – |            – |     44.3 ±0% |  0.02 ±0% |     0.52 ±13% |    103149 ±0% |
| typing | wan150  |  52.4 ±1% |            – |            – |     44.2 ±0% |  0.02 ±1% |      0.68 ±6% |    103149 ±0% |
| scroll | lan     |  61.5 ±1% |            – |            – |    40696 ±0% |  20.0 ±1% |     1.78 ±11% |   4096000 ±0% |
| scroll | wan150  |  51.8 ±1% |            – |            – |    40736 ±0% |  16.9 ±1% |     2.06 ±44% |   4096000 ±0% |
| photo  | lan     |  18.8 ±0% |            – |            – |  2923576 ±0% | 438.9 ±0% |      9.01 ±0% |   4096000 ±0% |
| photo  | wan150  |  2.14 ±0% |            – |            – |  2923587 ±0% |  50.0 ±0% |      21.5 ±3% |   4096000 ±0% |
| input  | lan     |         – |     3.37 ±2% |     3.58 ±5% |            – |         – |             – |             – |
| input  | wan150  |         – |    161.4 ±1% |    174.0 ±4% |            – |         – |             – |             – |

## Against /Users/alexandru/codevisor/c1c03091-66c4-4d69-808e-48293c61de1e/currant/tmp/vnc-bench/2026-09-23T151327Z/main/bench.json (build `main 200a6de6facb`)

| case          | metric        | baseline | current | change | verdict     |
| ------------- | ------------- | -------: | ------: | -----: | ----------- |
| input/lan     | input p50 ms  |     3.34 |    3.37 |    +1% | withinNoise |
| input/lan     | input p95 ms  |     3.48 |    3.58 |    +3% | withinNoise |
| input/wan150  | input p50 ms  |    161.2 |   161.4 |    +0% | withinNoise |
| input/wan150  | input p95 ms  |    170.8 |   174.0 |    +2% | withinNoise |
| photo/lan     | updates/s     |     18.6 |    18.8 |    +1% | withinNoise |
| photo/lan     | bytes/update  |  2923576 | 2923576 |    +0% | withinNoise |
| photo/lan     | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| photo/wan150  | updates/s     |     2.14 |    2.14 |    +0% | withinNoise |
| photo/wan150  | bytes/update  |  2923587 | 2923587 |    +0% | withinNoise |
| photo/wan150  | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/lan    | updates/s     |     61.5 |    61.5 |    +0% | withinNoise |
| scroll/lan    | bytes/update  |    40696 |   40696 |    +0% | withinNoise |
| scroll/lan    | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/wan150 | updates/s     |     52.4 |    51.8 |    -1% | withinNoise |
| scroll/wan150 | bytes/update  |    40736 |   40736 |    +0% | withinNoise |
| scroll/wan150 | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| typing/lan    | updates/s     |     62.1 |    61.7 |    -1% | withinNoise |
| typing/lan    | bytes/update  |     44.3 |    44.3 |    +0% | withinNoise |
| typing/lan    | copied/update |   103149 |  103149 |    +0% | withinNoise |
| typing/wan150 | updates/s     |     52.8 |    52.4 |    -1% | withinNoise |
| typing/wan150 | bytes/update  |     44.2 |    44.2 |    +0% | withinNoise |
| typing/wan150 | copied/update |   103149 |  103149 |    +0% | withinNoise |
