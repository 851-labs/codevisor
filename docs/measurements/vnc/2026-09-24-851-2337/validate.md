# 851-2337 — vnc:validate

Build `38228202d7f2` on Mac16,6. Verdict: **PASS**.

| Layer   | Result |  Time | Summary                                                                                                             |
| ------- | ------ | ----: | ------------------------------------------------------------------------------------------------------------------- |
| tests   | pass   |  30 s | packages/swift (RFB\|VNC\|ScreenSharingDiagnostics\|ScreenSharingViewerEndpoint): 325 tests; rig package: 102 tests |
| interop | pass   |  14 s | vnc:interop: PASS — 10 test(s) ran, 0 skipped                                                                       |
| bench   | pass   | 428 s | vnc-bench: no regression beyond the noise band                                                                      |
| tophat  | pass   |  26 s | vnc:tophat: PASS — 24/24 steps.                                                                                     |

## bench

Machine: Mac16,6, macOS 27.2, AC, load 3.9. Build: `38228202d7f2`.

Median of 3 run(s) per case; ± is the noise band (largest run deviation).

| scene  | profile | updates/s | input p50 ms | input p95 ms | bytes/update |    Mbit/s | CPU ms/update | copied/update | link est. Mbit/s |
| ------ | ------- | --------: | -----------: | -----------: | -----------: | --------: | ------------: | ------------: | ---------------: |
| typing | lan     |  61.7 ±1% |            – |            – |     44.3 ±0% |  0.02 ±1% |      0.71 ±6% |    103149 ±0% |                – |
| typing | wan150  |  52.9 ±0% |            – |            – |     44.2 ±0% |  0.02 ±0% |      0.84 ±8% |    103149 ±0% |                – |
| scroll | lan     |  61.2 ±0% |            – |            – |    40696 ±0% |  19.9 ±0% |      2.01 ±5% |   4096000 ±0% |                – |
| scroll | wan150  |  52.3 ±1% |            – |            – |    40736 ±0% |  17.1 ±1% |      2.22 ±2% |   4096000 ±0% |                – |
| photo  | lan     |  18.6 ±1% |            – |            – |  2923576 ±0% | 434.1 ±1% |      9.10 ±0% |   4096000 ±0% |        484.5 ±2% |
| photo  | wan150  |  2.14 ±0% |            – |            – |  2923587 ±0% |  50.0 ±0% |     21.1 ±21% |   4096000 ±0% |         46.1 ±1% |
| input  | lan     |         – |     3.38 ±3% |     3.63 ±8% |            – |         – |             – |             – |                – |
| input  | wan150  |         – |    160.4 ±1% |    170.2 ±1% |            – |         – |             – |             – |                – |

## Against /Users/alexandru/codevisor/c1c03091-66c4-4d69-808e-48293c61de1e/currant/tmp/vnc-bench/2026-09-24T005028Z/main/bench.json (build `main d11b5a92717b`)

| case          | metric        | baseline | current | change | verdict     |
| ------------- | ------------- | -------: | ------: | -----: | ----------- |
| input/lan     | input p50 ms  |     3.35 |    3.38 |    +1% | withinNoise |
| input/lan     | input p95 ms  |     3.65 |    3.63 |    -1% | withinNoise |
| input/wan150  | input p50 ms  |    159.5 |   160.4 |    +1% | withinNoise |
| input/wan150  | input p95 ms  |    170.7 |   170.2 |    -0% | withinNoise |
| photo/lan     | updates/s     |     18.5 |    18.6 |    +0% | withinNoise |
| photo/lan     | bytes/update  |  2923576 | 2923576 |    +0% | withinNoise |
| photo/lan     | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| photo/wan150  | updates/s     |     2.14 |    2.14 |    +0% | withinNoise |
| photo/wan150  | bytes/update  |  2923587 | 2923587 |    +0% | withinNoise |
| photo/wan150  | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/lan    | updates/s     |     61.3 |    61.2 |    -0% | withinNoise |
| scroll/lan    | bytes/update  |    40696 |   40696 |    +0% | withinNoise |
| scroll/lan    | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/wan150 | updates/s     |     52.5 |    52.3 |    -0% | withinNoise |
| scroll/wan150 | bytes/update  |    40736 |   40736 |    +0% | withinNoise |
| scroll/wan150 | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| typing/lan    | updates/s     |     62.1 |    61.7 |    -1% | withinNoise |
| typing/lan    | bytes/update  |     44.3 |    44.3 |    +0% | withinNoise |
| typing/lan    | copied/update |   103149 |  103149 |    +0% | withinNoise |
| typing/wan150 | updates/s     |     53.1 |    52.9 |    -0% | withinNoise |
| typing/wan150 | bytes/update  |     44.2 |    44.2 |    +0% | withinNoise |
| typing/wan150 | copied/update |   103149 |  103149 |    +0% | withinNoise |
