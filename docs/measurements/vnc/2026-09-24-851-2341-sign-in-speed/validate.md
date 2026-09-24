# 851-2341 (sign-in speed) — vnc:validate

Build `c25a3ec51412+dirty` on Mac16,6. Verdict: **PASS**.

| Layer   | Result |  Time | Summary                                                                                                             |
| ------- | ------ | ----: | ------------------------------------------------------------------------------------------------------------------- |
| tests   | pass   |  22 s | packages/swift (RFB\|VNC\|ScreenSharingDiagnostics\|ScreenSharingViewerEndpoint): 341 tests; rig package: 104 tests |
| interop | pass   |  16 s | vnc:interop: PASS — 10 test(s) ran, 0 skipped                                                                       |
| bench   | pass   | 441 s | vnc-bench: no regression beyond the noise band                                                                      |
| tophat  | pass   |  30 s | vnc:tophat: PASS — 24/24 steps.                                                                                     |

## bench

Machine: Mac16,6, macOS 27.2, AC, load 4.5. Build: `c25a3ec51412+dirty`.

Median of 3 run(s) per case; ± is the noise band (largest run deviation).

| scene  | profile | updates/s | input p50 ms | input p95 ms | bytes/update |    Mbit/s | CPU ms/update | copied/update | link est. Mbit/s |
| ------ | ------- | --------: | -----------: | -----------: | -----------: | --------: | ------------: | ------------: | ---------------: |
| typing | lan     |  62.0 ±0% |            – |            – |     44.3 ±0% |  0.02 ±0% |     0.52 ±51% |    103149 ±0% |                – |
| typing | wan150  |  53.4 ±2% |            – |            – |     44.2 ±0% |  0.02 ±2% |     0.59 ±11% |    103149 ±0% |                – |
| scroll | lan     |  61.5 ±1% |            – |            – |    40696 ±0% |  20.0 ±1% |     1.66 ±10% |   4096000 ±0% |                – |
| scroll | wan150  |  52.1 ±1% |            – |            – |    40736 ±0% |  17.0 ±1% |      1.88 ±5% |   4096000 ±0% |                – |
| photo  | lan     |  18.5 ±0% |            – |            – |  2923576 ±0% | 433.7 ±0% |      8.91 ±0% |   4096000 ±0% |       497.6 ±38% |
| photo  | wan150  |  2.14 ±0% |            – |            – |  2923587 ±0% |  50.0 ±0% |      21.2 ±1% |   4096000 ±0% |         48.5 ±1% |
| input  | lan     |         – |     3.22 ±0% |     3.52 ±4% |            – |         – |             – |             – |                – |
| input  | wan150  |         – |    155.8 ±1% |    163.5 ±2% |            – |         – |             – |             – |                – |

## Against /Users/alexandru/codevisor/c1c03091-66c4-4d69-808e-48293c61de1e/currant/tmp/vnc-bench/2026-09-24T181012Z/main/bench.json (build `main c25a3ec51412`)

| case          | metric        | baseline | current | change | verdict     |
| ------------- | ------------- | -------: | ------: | -----: | ----------- |
| input/lan     | input p50 ms  |     3.20 |    3.22 |    +1% | withinNoise |
| input/lan     | input p95 ms  |     3.33 |    3.52 |    +6% | withinNoise |
| input/wan150  | input p50 ms  |    156.5 |   155.8 |    -0% | withinNoise |
| input/wan150  | input p95 ms  |    165.2 |   163.5 |    -1% | withinNoise |
| photo/lan     | updates/s     |     18.6 |    18.5 |    -0% | withinNoise |
| photo/lan     | bytes/update  |  2923576 | 2923576 |    +0% | withinNoise |
| photo/lan     | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| photo/wan150  | updates/s     |     2.14 |    2.14 |    +0% | withinNoise |
| photo/wan150  | bytes/update  |  2923587 | 2923587 |    +0% | withinNoise |
| photo/wan150  | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/lan    | updates/s     |     60.9 |    61.5 |    +1% | withinNoise |
| scroll/lan    | bytes/update  |    40696 |   40696 |    +0% | withinNoise |
| scroll/lan    | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/wan150 | updates/s     |     52.3 |    52.1 |    -0% | withinNoise |
| scroll/wan150 | bytes/update  |    40736 |   40736 |    +0% | withinNoise |
| scroll/wan150 | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| typing/lan    | updates/s     |     61.4 |    62.0 |    +1% | withinNoise |
| typing/lan    | bytes/update  |     44.3 |    44.3 |    +0% | withinNoise |
| typing/lan    | copied/update |   103149 |  103149 |    +0% | withinNoise |
| typing/wan150 | updates/s     |     54.0 |    53.4 |    -1% | withinNoise |
| typing/wan150 | bytes/update  |     44.2 |    44.2 |    +0% | withinNoise |
| typing/wan150 | copied/update |   103149 |  103149 |    +0% | withinNoise |
