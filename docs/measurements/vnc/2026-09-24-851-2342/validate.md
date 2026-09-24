# 851-2342 — vnc:validate

Build `8c61d1cad785+dirty` on Mac16,6. Verdict: **PASS**.

| Layer   | Result |  Time | Summary                                                                                                             |
| ------- | ------ | ----: | ------------------------------------------------------------------------------------------------------------------- |
| tests   | pass   |  20 s | packages/swift (RFB\|VNC\|ScreenSharingDiagnostics\|ScreenSharingViewerEndpoint): 339 tests; rig package: 104 tests |
| interop | pass   |  14 s | vnc:interop: PASS — 10 test(s) ran, 0 skipped                                                                       |
| bench   | pass   | 426 s | vnc-bench: no regression beyond the noise band                                                                      |
| tophat  | pass   |  37 s | vnc:tophat: PASS — 24/24 steps.                                                                                     |

## bench

Machine: Mac16,6, macOS 27.2, battery, load 2.6. Build: `8c61d1cad785+dirty`.

Median of 3 run(s) per case; ± is the noise band (largest run deviation).

| scene  | profile | updates/s | input p50 ms | input p95 ms | bytes/update |    Mbit/s | CPU ms/update | copied/update | link est. Mbit/s |
| ------ | ------- | --------: | -----------: | -----------: | -----------: | --------: | ------------: | ------------: | ---------------: |
| typing | lan     |  62.0 ±1% |            – |            – |     44.3 ±0% |  0.02 ±1% |     0.42 ±55% |    103149 ±0% |                – |
| typing | wan150  |  50.4 ±4% |            – |            – |     44.2 ±0% |  0.02 ±4% |     0.71 ±62% |    103149 ±0% |                – |
| scroll | lan     |  62.0 ±0% |            – |            – |    40696 ±0% |  20.2 ±0% |      1.71 ±7% |   4096000 ±0% |                – |
| scroll | wan150  |  53.7 ±1% |            – |            – |    40736 ±0% |  17.5 ±1% |      2.03 ±4% |   4096000 ±0% |                – |
| photo  | lan     |  18.7 ±1% |            – |            – |  2923576 ±0% | 437.8 ±1% |      8.92 ±0% |   4096000 ±0% |        492.6 ±1% |
| photo  | wan150  |  2.14 ±0% |            – |            – |  2923587 ±0% |  50.0 ±0% |      20.6 ±4% |   4096000 ±0% |         48.3 ±1% |
| input  | lan     |         – |     3.38 ±1% |     3.74 ±9% |            – |         – |             – |             – |                – |
| input  | wan150  |         – |    156.3 ±1% |    165.3 ±1% |            – |         – |             – |             – |                – |

## Against /Users/alexandru/codevisor/c1c03091-66c4-4d69-808e-48293c61de1e/currant/tmp/vnc-bench/2026-09-24T030638Z/main/bench.json (build `main d1744c7c5382`)

| case          | metric        | baseline | current | change | verdict     |
| ------------- | ------------- | -------: | ------: | -----: | ----------- |
| input/lan     | input p50 ms  |     3.38 |    3.38 |    +0% | withinNoise |
| input/lan     | input p95 ms  |     3.68 |    3.74 |    +2% | withinNoise |
| input/wan150  | input p50 ms  |    156.1 |   156.3 |    +0% | withinNoise |
| input/wan150  | input p95 ms  |    165.2 |   165.3 |    +0% | withinNoise |
| photo/lan     | updates/s     |     18.3 |    18.7 |    +2% | withinNoise |
| photo/lan     | bytes/update  |  2923576 | 2923576 |    +0% | withinNoise |
| photo/lan     | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| photo/wan150  | updates/s     |     2.14 |    2.14 |    +0% | withinNoise |
| photo/wan150  | bytes/update  |  2923587 | 2923587 |    +0% | withinNoise |
| photo/wan150  | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/lan    | updates/s     |     61.4 |    62.0 |    +1% | withinNoise |
| scroll/lan    | bytes/update  |    40696 |   40696 |    +0% | withinNoise |
| scroll/lan    | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/wan150 | updates/s     |     52.3 |    53.7 |    +3% | withinNoise |
| scroll/wan150 | bytes/update  |    40736 |   40736 |    +0% | withinNoise |
| scroll/wan150 | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| typing/lan    | updates/s     |     62.2 |    62.0 |    -0% | withinNoise |
| typing/lan    | bytes/update  |     44.3 |    44.3 |    +0% | withinNoise |
| typing/lan    | copied/update |   103149 |  103149 |    +0% | withinNoise |
| typing/wan150 | updates/s     |     52.5 |    50.4 |    -4% | withinNoise |
| typing/wan150 | bytes/update  |     44.2 |    44.2 |    +0% | withinNoise |
| typing/wan150 | copied/update |   103149 |  103149 |    +0% | withinNoise |
