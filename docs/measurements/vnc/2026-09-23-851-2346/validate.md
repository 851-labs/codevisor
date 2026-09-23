# 851-2346 — vnc:validate

Build `c96c3488a49f+dirty` on Mac16,6. Verdict: **PASS**.

| Layer   | Result |  Time | Summary                                                                                                             |
| ------- | ------ | ----: | ------------------------------------------------------------------------------------------------------------------- |
| tests   | pass   |  20 s | packages/swift (RFB\|VNC\|ScreenSharingDiagnostics\|ScreenSharingViewerEndpoint): 325 tests; rig package: 101 tests |
| interop | pass   |  13 s | vnc:interop: PASS — 10 test(s) ran, 0 skipped                                                                       |
| bench   | pass   | 401 s | vnc-bench: no regression beyond the noise band                                                                      |
| tophat  | pass   |  27 s | vnc:tophat: PASS — 24/24 steps.                                                                                     |

## bench

Machine: Mac16,6, macOS 27.2, battery, load 3.0. Build: `c96c3488a49f+dirty`.

Median of 3 run(s) per case; ± is the noise band (largest run deviation).

| scene  | profile | updates/s | input p50 ms | input p95 ms | bytes/update |    Mbit/s | CPU ms/update | copied/update | link est. Mbit/s |
| ------ | ------- | --------: | -----------: | -----------: | -----------: | --------: | ------------: | ------------: | ---------------: |
| typing | lan     |  62.3 ±0% |            – |            – |     44.3 ±0% |  0.02 ±0% |      0.60 ±3% |    103149 ±0% |                – |
| typing | wan150  |  53.8 ±5% |            – |            – |     44.2 ±0% |  0.02 ±5% |     0.66 ±58% |    103149 ±0% |                – |
| scroll | lan     |  61.6 ±0% |            – |            – |    40696 ±0% |  20.1 ±0% |      1.79 ±7% |   4096000 ±0% |                – |
| scroll | wan150  |  52.3 ±1% |            – |            – |    40736 ±0% |  17.0 ±1% |      2.17 ±0% |   4096000 ±0% |                – |
| photo  | lan     |  19.0 ±0% |            – |            – |  2923576 ±0% | 445.4 ±0% |      8.66 ±1% |   4096000 ±0% |        494.2 ±1% |
| photo  | wan150  |  2.14 ±0% |            – |            – |  2923587 ±0% |  50.0 ±0% |      19.9 ±8% |   4096000 ±0% |         48.4 ±0% |
| input  | lan     |         – |     3.36 ±1% |     3.49 ±2% |            – |         – |             – |             – |                – |
| input  | wan150  |         – |    155.0 ±1% |    164.7 ±0% |            – |         – |             – |             – |                – |

## Against /Users/alexandru/codevisor/c1c03091-66c4-4d69-808e-48293c61de1e/currant/tmp/vnc-bench/2026-09-23T232808Z/main/bench.json (build `main c96c3488a49f`)

| case          | metric        | baseline | current | change | verdict     |
| ------------- | ------------- | -------: | ------: | -----: | ----------- |
| input/lan     | input p50 ms  |     3.37 |    3.36 |    -0% | withinNoise |
| input/lan     | input p95 ms  |     3.50 |    3.49 |    -0% | withinNoise |
| input/wan150  | input p50 ms  |    155.4 |   155.0 |    -0% | withinNoise |
| input/wan150  | input p95 ms  |    165.2 |   164.7 |    -0% | withinNoise |
| photo/lan     | updates/s     |     18.7 |    19.0 |    +2% | withinNoise |
| photo/lan     | bytes/update  |  2923576 | 2923576 |    +0% | withinNoise |
| photo/lan     | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| photo/wan150  | updates/s     |     2.14 |    2.14 |    -0% | withinNoise |
| photo/wan150  | bytes/update  |  2923587 | 2923587 |    +0% | withinNoise |
| photo/wan150  | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/lan    | updates/s     |     61.3 |    61.6 |    +0% | withinNoise |
| scroll/lan    | bytes/update  |    40696 |   40696 |    +0% | withinNoise |
| scroll/lan    | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/wan150 | updates/s     |     53.2 |    52.3 |    -2% | withinNoise |
| scroll/wan150 | bytes/update  |    40736 |   40736 |    +0% | withinNoise |
| scroll/wan150 | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| typing/lan    | updates/s     |     62.2 |    62.3 |    +0% | withinNoise |
| typing/lan    | bytes/update  |     44.3 |    44.3 |    +0% | withinNoise |
| typing/lan    | copied/update |   103149 |  103149 |    +0% | withinNoise |
| typing/wan150 | updates/s     |     53.1 |    53.8 |    +1% | withinNoise |
| typing/wan150 | bytes/update  |     44.2 |    44.2 |    +0% | withinNoise |
| typing/wan150 | copied/update |   103149 |  103149 |    +0% | withinNoise |
