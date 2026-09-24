# 851-2338 — vnc:validate

Build `5ae3299021ff+dirty` on Mac16,6. Verdict: **PASS**.

| Layer   | Result |  Time | Summary                                                                                                             |
| ------- | ------ | ----: | ------------------------------------------------------------------------------------------------------------------- |
| tests   | pass   |  32 s | packages/swift (RFB\|VNC\|ScreenSharingDiagnostics\|ScreenSharingViewerEndpoint): 330 tests; rig package: 102 tests |
| interop | pass   |  16 s | vnc:interop: PASS — 10 test(s) ran, 0 skipped                                                                       |
| bench   | pass   | 449 s | vnc-bench: no regression beyond the noise band                                                                      |
| tophat  | pass   |  30 s | vnc:tophat: PASS — 24/24 steps.                                                                                     |

## bench

Machine: Mac16,6, macOS 27.2, AC, load 2.4. Build: `5ae3299021ff+dirty`.

Median of 3 run(s) per case; ± is the noise band (largest run deviation).

| scene  | profile | updates/s | input p50 ms | input p95 ms | bytes/update |    Mbit/s | CPU ms/update | copied/update | link est. Mbit/s |
| ------ | ------- | --------: | -----------: | -----------: | -----------: | --------: | ------------: | ------------: | ---------------: |
| typing | lan     |  62.1 ±1% |            – |            – |     44.3 ±0% |  0.02 ±1% |      0.56 ±4% |    103149 ±0% |                – |
| typing | wan150  |  52.4 ±1% |            – |            – |     44.2 ±0% |  0.02 ±1% |      0.68 ±4% |    103149 ±0% |                – |
| scroll | lan     |  61.4 ±1% |            – |            – |    40696 ±0% |  20.0 ±1% |      1.81 ±5% |   4096000 ±0% |                – |
| scroll | wan150  |  52.4 ±3% |            – |            – |    40736 ±0% |  17.1 ±3% |     1.07 ±98% |   4096000 ±0% |                – |
| photo  | lan     |  18.4 ±0% |            – |            – |  2923576 ±0% | 431.5 ±0% |      9.10 ±1% |   4096000 ±0% |        488.2 ±1% |
| photo  | wan150  |  2.14 ±0% |            – |            – |  2923587 ±0% |  50.0 ±0% |      22.1 ±4% |   4096000 ±0% |         45.9 ±1% |
| input  | lan     |         – |     3.21 ±1% |     3.32 ±6% |            – |         – |             – |             – |                – |
| input  | wan150  |         – |    160.6 ±1% |    169.7 ±2% |            – |         – |             – |             – |                – |

## Against /Users/alexandru/codevisor/c1c03091-66c4-4d69-808e-48293c61de1e/currant/tmp/vnc-bench/2026-09-24T023657Z/main/bench.json (build `main 5ae3299021ff`)

| case          | metric        | baseline | current | change | verdict     |
| ------------- | ------------- | -------: | ------: | -----: | ----------- |
| input/lan     | input p50 ms  |     3.34 |    3.21 |    -4% | withinNoise |
| input/lan     | input p95 ms  |     3.46 |    3.32 |    -4% | withinNoise |
| input/wan150  | input p50 ms  |    160.4 |   160.6 |    +0% | withinNoise |
| input/wan150  | input p95 ms  |    171.3 |   169.7 |    -1% | withinNoise |
| photo/lan     | updates/s     |     18.2 |    18.4 |    +1% | withinNoise |
| photo/lan     | bytes/update  |  2923576 | 2923576 |    +0% | withinNoise |
| photo/lan     | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| photo/wan150  | updates/s     |     2.14 |    2.14 |    -0% | withinNoise |
| photo/wan150  | bytes/update  |  2923587 | 2923587 |    +0% | withinNoise |
| photo/wan150  | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/lan    | updates/s     |     61.5 |    61.4 |    -0% | withinNoise |
| scroll/lan    | bytes/update  |    40696 |   40696 |    +0% | withinNoise |
| scroll/lan    | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/wan150 | updates/s     |     52.2 |    52.4 |    +0% | withinNoise |
| scroll/wan150 | bytes/update  |    40736 |   40736 |    +0% | withinNoise |
| scroll/wan150 | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| typing/lan    | updates/s     |     62.0 |    62.1 |    +0% | withinNoise |
| typing/lan    | bytes/update  |     44.3 |    44.3 |    +0% | withinNoise |
| typing/lan    | copied/update |   103149 |  103149 |    +0% | withinNoise |
| typing/wan150 | updates/s     |     52.5 |    52.4 |    -0% | withinNoise |
| typing/wan150 | bytes/update  |     44.2 |    44.2 |    +0% | withinNoise |
| typing/wan150 | copied/update |   103149 |  103149 |    +0% | withinNoise |
