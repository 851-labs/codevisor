# 851-2335 — vnc:validate

Build `7b6f07d579fc` on Mac16,6. Verdict: **PASS**.

| Layer   | Result |  Time | Summary                                                                                                             |
| ------- | ------ | ----: | ------------------------------------------------------------------------------------------------------------------- |
| tests   | pass   |  30 s | packages/swift (RFB\|VNC\|ScreenSharingDiagnostics\|ScreenSharingViewerEndpoint): 325 tests; rig package: 102 tests |
| interop | pass   |  16 s | vnc:interop: PASS — 10 test(s) ran, 0 skipped                                                                       |
| bench   | pass   | 467 s | vnc-bench: no regression beyond the noise band                                                                      |
| tophat  | pass   |  30 s | vnc:tophat: PASS — 24/24 steps.                                                                                     |

## bench

Machine: Mac16,6, macOS 27.2, AC, load 2.7. Build: `7b6f07d579fc`.

Median of 3 run(s) per case; ± is the noise band (largest run deviation).

| scene  | profile | updates/s | input p50 ms | input p95 ms | bytes/update |    Mbit/s | CPU ms/update | copied/update | link est. Mbit/s |
| ------ | ------- | --------: | -----------: | -----------: | -----------: | --------: | ------------: | ------------: | ---------------: |
| typing | lan     |  62.5 ±1% |            – |            – |     44.3 ±0% |  0.02 ±1% |     0.44 ±44% |    103149 ±0% |                – |
| typing | wan150  |  51.1 ±1% |            – |            – |     44.2 ±0% |  0.02 ±1% |      0.28 ±1% |    103149 ±0% |                – |
| scroll | lan     |  61.4 ±1% |            – |            – |    40696 ±0% |  20.0 ±1% |      0.57 ±9% |   4096000 ±0% |                – |
| scroll | wan150  |  53.5 ±2% |            – |            – |    40736 ±0% |  17.4 ±2% |     2.19 ±10% |   4096000 ±0% |                – |
| photo  | lan     |  18.6 ±0% |            – |            – |  2923576 ±0% | 434.1 ±0% |      9.07 ±0% |   4096000 ±0% |        492.8 ±1% |
| photo  | wan150  |  2.14 ±0% |            – |            – |  2923587 ±0% |  50.0 ±0% |      21.2 ±5% |   4096000 ±0% |         47.1 ±3% |
| input  | lan     |         – |     3.32 ±2% |    3.46 ±12% |            – |         – |             – |             – |                – |
| input  | wan150  |         – |    156.6 ±1% |    163.3 ±0% |            – |         – |             – |             – |                – |

## Against /Users/alexandru/codevisor/c1c03091-66c4-4d69-808e-48293c61de1e/currant/tmp/vnc-bench/2026-09-24T011100Z/main/bench.json (build `main 19721fca4c60`)

| case          | metric        | baseline | current | change | verdict     |
| ------------- | ------------- | -------: | ------: | -----: | ----------- |
| input/lan     | input p50 ms  |     3.34 |    3.32 |    -1% | withinNoise |
| input/lan     | input p95 ms  |     3.50 |    3.46 |    -1% | withinNoise |
| input/wan150  | input p50 ms  |    156.1 |   156.6 |    +0% | withinNoise |
| input/wan150  | input p95 ms  |    166.2 |   163.3 |    -2% | withinNoise |
| photo/lan     | updates/s     |     18.1 |    18.6 |    +3% | withinNoise |
| photo/lan     | bytes/update  |  2923576 | 2923576 |    +0% | withinNoise |
| photo/lan     | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| photo/wan150  | updates/s     |     2.14 |    2.14 |    +0% | withinNoise |
| photo/wan150  | bytes/update  |  2923587 | 2923587 |    +0% | withinNoise |
| photo/wan150  | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/lan    | updates/s     |     60.9 |    61.4 |    +1% | withinNoise |
| scroll/lan    | bytes/update  |    40696 |   40696 |    +0% | withinNoise |
| scroll/lan    | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/wan150 | updates/s     |     53.1 |    53.5 |    +1% | withinNoise |
| scroll/wan150 | bytes/update  |    40736 |   40736 |    +0% | withinNoise |
| scroll/wan150 | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| typing/lan    | updates/s     |     62.1 |    62.5 |    +1% | withinNoise |
| typing/lan    | bytes/update  |     44.3 |    44.3 |    +0% | withinNoise |
| typing/lan    | copied/update |   103149 |  103149 |    +0% | withinNoise |
| typing/wan150 | updates/s     |     53.6 |    51.1 |    -5% | withinNoise |
| typing/wan150 | bytes/update  |     44.2 |    44.2 |    +0% | withinNoise |
| typing/wan150 | copied/update |   103149 |  103149 |    +0% | withinNoise |
