# 851-2339 — vnc:validate

Build `91f7e96aa833` on Mac16,6. Verdict: **PASS**.

| Layer   | Result |  Time | Summary                                                                                                             |
| ------- | ------ | ----: | ------------------------------------------------------------------------------------------------------------------- |
| tests   | pass   |  32 s | packages/swift (RFB\|VNC\|ScreenSharingDiagnostics\|ScreenSharingViewerEndpoint): 325 tests; rig package: 102 tests |
| interop | pass   |  14 s | vnc:interop: PASS — 10 test(s) ran, 0 skipped                                                                       |
| bench   | pass   | 393 s | vnc-bench: no regression beyond the noise band                                                                      |
| tophat  | pass   |  26 s | vnc:tophat: PASS — 24/24 steps.                                                                                     |

## bench

Machine: Mac16,6, macOS 27.2, AC, load 3.3. Build: `91f7e96aa833`.

Median of 3 run(s) per case; ± is the noise band (largest run deviation).

| scene  | profile | updates/s | input p50 ms | input p95 ms | bytes/update |    Mbit/s | CPU ms/update | copied/update | link est. Mbit/s |
| ------ | ------- | --------: | -----------: | -----------: | -----------: | --------: | ------------: | ------------: | ---------------: |
| typing | lan     |  62.2 ±0% |            – |            – |     44.3 ±0% |  0.02 ±0% |     0.70 ±10% |    103149 ±0% |                – |
| typing | wan150  |  52.3 ±1% |            – |            – |     44.2 ±0% |  0.02 ±1% |      0.76 ±2% |    103149 ±0% |                – |
| scroll | lan     |  61.4 ±0% |            – |            – |    40696 ±0% |  20.0 ±0% |      1.90 ±5% |   4096000 ±0% |                – |
| scroll | wan150  |  52.3 ±3% |            – |            – |    40736 ±0% |  17.1 ±3% |     1.67 ±29% |   4096000 ±0% |                – |
| photo  | lan     |  18.6 ±0% |            – |            – |  2923576 ±0% | 435.3 ±0% |      9.06 ±0% |   4096000 ±0% |        494.9 ±1% |
| photo  | wan150  |  2.14 ±0% |            – |            – |  2923587 ±0% |  50.0 ±0% |      21.3 ±8% |   4096000 ±0% |         46.6 ±1% |
| input  | lan     |         – |     3.38 ±2% |     3.72 ±8% |            – |         – |             – |             – |                – |
| input  | wan150  |         – |    160.8 ±1% |    171.2 ±0% |            – |         – |             – |             – |                – |

## Against /Users/alexandru/codevisor/c1c03091-66c4-4d69-808e-48293c61de1e/currant/tmp/vnc-bench/2026-09-24T010048Z/main/bench.json (build `main f3225f604bbc`)

| case          | metric        | baseline | current | change | verdict     |
| ------------- | ------------- | -------: | ------: | -----: | ----------- |
| input/lan     | input p50 ms  |     3.23 |    3.38 |    +5% | withinNoise |
| input/lan     | input p95 ms  |     3.33 |    3.72 |   +12% | withinNoise |
| input/wan150  | input p50 ms  |    160.0 |   160.8 |    +1% | withinNoise |
| input/wan150  | input p95 ms  |    170.3 |   171.2 |    +1% | withinNoise |
| photo/lan     | updates/s     |     18.4 |    18.6 |    +1% | withinNoise |
| photo/lan     | bytes/update  |  2923576 | 2923576 |    +0% | withinNoise |
| photo/lan     | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| photo/wan150  | updates/s     |     2.14 |    2.14 |    -0% | withinNoise |
| photo/wan150  | bytes/update  |  2923587 | 2923587 |    +0% | withinNoise |
| photo/wan150  | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/lan    | updates/s     |     60.6 |    61.4 |    +1% | withinNoise |
| scroll/lan    | bytes/update  |    40696 |   40696 |    +0% | withinNoise |
| scroll/lan    | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/wan150 | updates/s     |     52.0 |    52.3 |    +1% | withinNoise |
| scroll/wan150 | bytes/update  |    40736 |   40736 |    +0% | withinNoise |
| scroll/wan150 | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| typing/lan    | updates/s     |     62.3 |    62.2 |    -0% | withinNoise |
| typing/lan    | bytes/update  |     44.3 |    44.3 |    +0% | withinNoise |
| typing/lan    | copied/update |   103149 |  103149 |    +0% | withinNoise |
| typing/wan150 | updates/s     |     53.1 |    52.3 |    -2% | withinNoise |
| typing/wan150 | bytes/update  |     44.2 |    44.2 |    +0% | withinNoise |
| typing/wan150 | copied/update |   103149 |  103149 |    +0% | withinNoise |
