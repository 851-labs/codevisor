# 851-2347 — vnc:validate

Build `89e871155e8b+dirty` on Mac16,6. Verdict: **PASS**.

| Layer   | Result |  Time | Summary                                                                                                             |
| ------- | ------ | ----: | ------------------------------------------------------------------------------------------------------------------- |
| tests   | pass   |  21 s | packages/swift (RFB\|VNC\|ScreenSharingDiagnostics\|ScreenSharingViewerEndpoint): 325 tests; rig package: 101 tests |
| interop | pass   |  16 s | vnc:interop: PASS — 10 test(s) ran, 0 skipped                                                                       |
| bench   | pass   | 407 s | vnc-bench: no regression beyond the noise band                                                                      |
| tophat  | pass   |  27 s | vnc:tophat: PASS — 24/24 steps.                                                                                     |

## bench

Machine: Mac16,6, macOS 27.2, AC, load 3.5. Build: `89e871155e8b+dirty`.

Median of 3 run(s) per case; ± is the noise band (largest run deviation).

| scene  | profile | updates/s | input p50 ms | input p95 ms | bytes/update |    Mbit/s | CPU ms/update | copied/update | link est. Mbit/s |
| ------ | ------- | --------: | -----------: | -----------: | -----------: | --------: | ------------: | ------------: | ---------------: |
| typing | lan     |  62.1 ±1% |            – |            – |     44.3 ±0% |  0.02 ±1% |      0.77 ±6% |    103149 ±0% |                – |
| typing | wan150  |  53.5 ±1% |            – |            – |     44.2 ±0% |  0.02 ±1% |     0.83 ±10% |    103149 ±0% |                – |
| scroll | lan     |  61.5 ±0% |            – |            – |    40696 ±0% |  20.0 ±0% |     1.88 ±12% |   4096000 ±0% |                – |
| scroll | wan150  |  53.4 ±1% |            – |            – |    40736 ±0% |  17.4 ±1% |     2.34 ±11% |   4096000 ±0% |                – |
| photo  | lan     |  18.5 ±1% |            – |            – |  2923576 ±0% | 432.2 ±1% |      9.22 ±1% |   4096000 ±0% |        484.4 ±4% |
| photo  | wan150  |  2.14 ±0% |            – |            – |  2923587 ±0% |  50.0 ±0% |      22.5 ±3% |   4096000 ±0% |         48.6 ±0% |
| input  | lan     |         – |     3.24 ±1% |     3.27 ±2% |            – |         – |             – |             – |                – |
| input  | wan150  |         – |    155.0 ±0% |    164.8 ±1% |            – |         – |             – |             – |                – |

## Against /Users/alexandru/codevisor/c1c03091-66c4-4d69-808e-48293c61de1e/currant/tmp/vnc-bench/2026-09-23T234056Z/main/bench.json (build `main 89e871155e8b`)

| case          | metric        | baseline | current | change | verdict     |
| ------------- | ------------- | -------: | ------: | -----: | ----------- |
| input/lan     | input p50 ms  |     3.37 |    3.24 |    -4% | withinNoise |
| input/lan     | input p95 ms  |     3.63 |    3.27 |   -10% | withinNoise |
| input/wan150  | input p50 ms  |    155.4 |   155.0 |    -0% | withinNoise |
| input/wan150  | input p95 ms  |    163.5 |   164.8 |    +1% | withinNoise |
| photo/lan     | updates/s     |     18.6 |    18.5 |    -0% | withinNoise |
| photo/lan     | bytes/update  |  2923576 | 2923576 |    +0% | withinNoise |
| photo/lan     | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| photo/wan150  | updates/s     |     2.14 |    2.14 |    +0% | withinNoise |
| photo/wan150  | bytes/update  |  2923587 | 2923587 |    +0% | withinNoise |
| photo/wan150  | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/lan    | updates/s     |     61.5 |    61.5 |    -0% | withinNoise |
| scroll/lan    | bytes/update  |    40696 |   40696 |    +0% | withinNoise |
| scroll/lan    | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/wan150 | updates/s     |     52.6 |    53.4 |    +2% | withinNoise |
| scroll/wan150 | bytes/update  |    40736 |   40736 |    +0% | withinNoise |
| scroll/wan150 | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| typing/lan    | updates/s     |     62.4 |    62.1 |    -1% | withinNoise |
| typing/lan    | bytes/update  |     44.3 |    44.3 |    +0% | withinNoise |
| typing/lan    | copied/update |   103149 |  103149 |    +0% | withinNoise |
| typing/wan150 | updates/s     |     53.2 |    53.5 |    +1% | withinNoise |
| typing/wan150 | bytes/update  |     44.2 |    44.2 |    +0% | withinNoise |
| typing/wan150 | copied/update |   103149 |  103149 |    +0% | withinNoise |
