# 851-2326 — vnc:validate

Build `8ec95aab313b+dirty` on Mac16,6. Verdict: **PASS**.

| Layer   | Result |  Time | Summary                                                                                                            |
| ------- | ------ | ----: | ------------------------------------------------------------------------------------------------------------------ |
| tests   | pass   |  18 s | packages/swift (RFB\|VNC\|ScreenSharingDiagnostics\|ScreenSharingViewerEndpoint): 292 tests; rig package: 92 tests |
| interop | pass   |  12 s | vnc:interop: PASS — 7 test(s) ran, 0 skipped                                                                       |
| bench   | pass   | 406 s | vnc-bench: no regression beyond the noise band                                                                     |
| tophat  | pass   |  25 s | vnc:tophat: PASS — 24/24 steps.                                                                                    |

## bench

Machine: Mac16,6, macOS 27.2, AC, load 2.9. Build: `8ec95aab313b+dirty`.

Median of 3 run(s) per case; ± is the noise band (largest run deviation).

| scene  | profile | updates/s | input p50 ms | input p95 ms | bytes/update |    Mbit/s | CPU ms/update | copied/update |
| ------ | ------- | --------: | -----------: | -----------: | -----------: | --------: | ------------: | ------------: |
| typing | lan     |  64.2 ±2% |            – |            – |     63.8 ±0% |  0.03 ±2% |      0.64 ±9% |   4096000 ±0% |
| typing | wan150  |  54.6 ±2% |            – |            – |     63.6 ±0% |  0.03 ±2% |      0.90 ±9% |   4096000 ±0% |
| scroll | lan     |  65.0 ±1% |            – |            – |    40689 ±0% |  21.2 ±1% |      1.07 ±8% |   4096000 ±0% |
| scroll | wan150  |  53.4 ±5% |            – |            – |    40732 ±0% |  17.4 ±5% |     1.46 ±14% |   4096000 ±0% |
| photo  | lan     |  18.0 ±1% |            – |            – |  3038227 ±0% | 438.5 ±1% |      8.23 ±1% |   4096000 ±0% |
| photo  | wan150  |  2.06 ±0% |            – |            – |  3038226 ±0% |  50.0 ±0% |      20.3 ±6% |   4096000 ±0% |
| input  | lan     |         – |     3.42 ±0% |     3.47 ±1% |            – |         – |             – |             – |
| input  | wan150  |         – |    160.7 ±2% |    170.3 ±1% |            – |         – |             – |             – |

## Against /Users/alexandru/codevisor/c1c03091-66c4-4d69-808e-48293c61de1e/currant/tmp/vnc-bench/2026-09-23T091905Z/main/bench.json (build `main 8ec95aab313b`)

| case          | metric        | baseline | current | change | verdict     |
| ------------- | ------------- | -------: | ------: | -----: | ----------- |
| input/lan     | input p50 ms  |     3.42 |    3.42 |    -0% | withinNoise |
| input/lan     | input p95 ms  |     3.48 |    3.47 |    -0% | withinNoise |
| input/wan150  | input p50 ms  |    163.0 |   160.7 |    -1% | withinNoise |
| input/wan150  | input p95 ms  |    170.7 |   170.3 |    -0% | withinNoise |
| photo/lan     | updates/s     |     17.7 |    18.0 |    +2% | withinNoise |
| photo/lan     | bytes/update  |  3038227 | 3038227 |    +0% | withinNoise |
| photo/lan     | CPU ms/update |     8.48 |    8.23 |    -3% | withinNoise |
| photo/lan     | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| photo/wan150  | updates/s     |     2.06 |    2.06 |    +0% | withinNoise |
| photo/wan150  | bytes/update  |  3038226 | 3038226 |    +0% | withinNoise |
| photo/wan150  | CPU ms/update |     21.0 |    20.3 |    -3% | withinNoise |
| photo/wan150  | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/lan    | updates/s     |     64.8 |    65.0 |    +0% | withinNoise |
| scroll/lan    | bytes/update  |    40689 |   40689 |    +0% | withinNoise |
| scroll/lan    | CPU ms/update |     1.12 |    1.07 |    -4% | withinNoise |
| scroll/lan    | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/wan150 | updates/s     |     54.5 |    53.4 |    -2% | withinNoise |
| scroll/wan150 | bytes/update  |    40732 |   40732 |    +0% | withinNoise |
| scroll/wan150 | CPU ms/update |     1.48 |    1.46 |    -1% | withinNoise |
| scroll/wan150 | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| typing/lan    | updates/s     |     62.6 |    64.2 |    +2% | withinNoise |
| typing/lan    | bytes/update  |     63.8 |    63.8 |    +0% | withinNoise |
| typing/lan    | CPU ms/update |     0.29 |    0.64 |  +120% | withinNoise |
| typing/lan    | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| typing/wan150 | updates/s     |     51.4 |    54.6 |    +6% | withinNoise |
| typing/wan150 | bytes/update  |     63.6 |    63.6 |    +0% | withinNoise |
| typing/wan150 | CPU ms/update |     0.53 |    0.90 |   +69% | withinNoise |
| typing/wan150 | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
