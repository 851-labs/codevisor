# 851-2341 — vnc:validate

Build `717df79bfc4a+dirty` on Mac16,6. Verdict: **PASS**.

| Layer   | Result |  Time | Summary                                                                                                             |
| ------- | ------ | ----: | ------------------------------------------------------------------------------------------------------------------- |
| tests   | pass   |  29 s | packages/swift (RFB\|VNC\|ScreenSharingDiagnostics\|ScreenSharingViewerEndpoint): 338 tests; rig package: 102 tests |
| interop | pass   |  16 s | vnc:interop: PASS — 10 test(s) ran, 0 skipped                                                                       |
| bench   | pass   | 439 s | vnc-bench: no regression beyond the noise band                                                                      |
| tophat  | pass   |  28 s | vnc:tophat: PASS — 24/24 steps.                                                                                     |

## bench

Machine: Mac16,6, macOS 27.2, battery, load 5.4. Build: `717df79bfc4a+dirty`.

Median of 3 run(s) per case; ± is the noise band (largest run deviation).

| scene  | profile | updates/s | input p50 ms | input p95 ms | bytes/update |    Mbit/s | CPU ms/update | copied/update | link est. Mbit/s |
| ------ | ------- | --------: | -----------: | -----------: | -----------: | --------: | ------------: | ------------: | ---------------: |
| typing | lan     |  62.2 ±1% |            – |            – |     44.3 ±0% |  0.02 ±1% |     0.56 ±13% |    103149 ±0% |                – |
| typing | wan150  |  52.9 ±5% |            – |            – |     44.2 ±0% |  0.02 ±5% |     0.63 ±32% |    103149 ±0% |                – |
| scroll | lan     |  61.9 ±0% |            – |            – |    40696 ±0% |  20.1 ±0% |      1.63 ±7% |   4096000 ±0% |                – |
| scroll | wan150  |  53.1 ±1% |            – |            – |    40736 ±0% |  17.3 ±1% |     1.92 ±12% |   4096000 ±0% |                – |
| photo  | lan     |  18.8 ±0% |            – |            – |  2923576 ±0% | 440.1 ±0% |      8.84 ±1% |   4096000 ±0% |        496.7 ±0% |
| photo  | wan150  |  2.14 ±0% |            – |            – |  2923587 ±0% |  50.0 ±0% |      21.5 ±3% |   4096000 ±0% |         48.3 ±1% |
| input  | lan     |         – |     3.41 ±4% |    4.34 ±18% |            – |         – |             – |             – |                – |
| input  | wan150  |         – |    155.3 ±1% |    164.1 ±0% |            – |         – |             – |             – |                – |

## Against /Users/alexandru/codevisor/c1c03091-66c4-4d69-808e-48293c61de1e/currant/tmp/vnc-bench/2026-09-24T025239Z/main/bench.json (build `main 678de6edb984`)

| case          | metric        | baseline | current | change | verdict     |
| ------------- | ------------- | -------: | ------: | -----: | ----------- |
| input/lan     | input p50 ms  |     3.38 |    3.41 |    +1% | withinNoise |
| input/lan     | input p95 ms  |     3.66 |    4.34 |   +19% | withinNoise |
| input/wan150  | input p50 ms  |    155.8 |   155.3 |    -0% | withinNoise |
| input/wan150  | input p95 ms  |    164.5 |   164.1 |    -0% | withinNoise |
| photo/lan     | updates/s     |     18.3 |    18.8 |    +3% | withinNoise |
| photo/lan     | bytes/update  |  2923576 | 2923576 |    +0% | withinNoise |
| photo/lan     | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| photo/wan150  | updates/s     |     2.14 |    2.14 |    -0% | withinNoise |
| photo/wan150  | bytes/update  |  2923587 | 2923587 |    +0% | withinNoise |
| photo/wan150  | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/lan    | updates/s     |     61.5 |    61.9 |    +1% | withinNoise |
| scroll/lan    | bytes/update  |    40696 |   40696 |    +0% | withinNoise |
| scroll/lan    | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/wan150 | updates/s     |     53.6 |    53.1 |    -1% | withinNoise |
| scroll/wan150 | bytes/update  |    40736 |   40736 |    +0% | withinNoise |
| scroll/wan150 | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| typing/lan    | updates/s     |     62.4 |    62.2 |    -0% | withinNoise |
| typing/lan    | bytes/update  |     44.3 |    44.3 |    +0% | withinNoise |
| typing/lan    | copied/update |   103149 |  103149 |    +0% | withinNoise |
| typing/wan150 | updates/s     |     53.1 |    52.9 |    -0% | withinNoise |
| typing/wan150 | bytes/update  |     44.2 |    44.2 |    +0% | withinNoise |
| typing/wan150 | copied/update |   103149 |  103149 |    +0% | withinNoise |
