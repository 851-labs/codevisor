# 851-2316 — vnc:validate

Build `04fd3ae29b9e+dirty` on Mac16,6. Verdict: **PASS**.

| Layer   | Result |  Time | Summary                                                                                                            |
| ------- | ------ | ----: | ------------------------------------------------------------------------------------------------------------------ |
| tests   | pass   |  19 s | packages/swift (RFB\|VNC\|ScreenSharingDiagnostics\|ScreenSharingViewerEndpoint): 288 tests; rig package: 92 tests |
| interop | pass   |  11 s | vnc:interop: PASS — 7 test(s) ran, 0 skipped                                                                       |
| bench   | pass   | 422 s | vnc-bench: no regression beyond the noise band                                                                     |
| tophat  | pass   |  25 s | vnc:tophat: PASS — 24/24 steps.                                                                                    |

## bench

Machine: Mac16,6, macOS 27.2, AC, load 3.3. Build: `04fd3ae29b9e+dirty`.

Median of 3 run(s) per case; ± is the noise band (largest run deviation).

| scene  | profile | updates/s | input p50 ms | input p95 ms | bytes/update |    Mbit/s | CPU ms/update | copied/update |
| ------ | ------- | --------: | -----------: | -----------: | -----------: | --------: | ------------: | ------------: |
| typing | lan     |  65.6 ±1% |            – |            – |     63.8 ±0% |  0.03 ±1% |     0.67 ±12% |   4096000 ±0% |
| typing | wan150  |  55.2 ±2% |            – |            – |     63.6 ±0% |  0.03 ±2% |      0.85 ±7% |   4096000 ±0% |
| scroll | lan     |  64.8 ±1% |            – |            – |    40689 ±0% |  21.1 ±1% |      1.05 ±7% |   4096000 ±0% |
| scroll | wan150  |  53.2 ±2% |            – |            – |    40732 ±0% |  17.3 ±2% |      1.56 ±7% |   4096000 ±0% |
| photo  | lan     |  17.7 ±1% |            – |            – |  3038227 ±0% | 429.9 ±1% |      8.46 ±1% |   4096000 ±0% |
| photo  | wan150  |  2.06 ±0% |            – |            – |  3038226 ±0% |  50.0 ±0% |      20.4 ±5% |   4096000 ±0% |
| input  | lan     |         – |     3.42 ±1% |     3.49 ±0% |            – |         – |             – |             – |
| input  | wan150  |         – |    163.5 ±1% |    170.2 ±1% |            – |         – |             – |             – |

## Against /Users/alexandru/codevisor/c1c03091-66c4-4d69-808e-48293c61de1e/currant/tmp/vnc-bench/2026-09-23T090627Z/main/bench.json (build `main daba6e9a82d6`)

| case          | metric        | baseline | current | change | verdict     |
| ------------- | ------------- | -------: | ------: | -----: | ----------- |
| input/lan     | input p50 ms  |     3.43 |    3.42 |    -0% | withinNoise |
| input/lan     | input p95 ms  |     3.48 |    3.49 |    +0% | withinNoise |
| input/wan150  | input p50 ms  |    164.2 |   163.5 |    -0% | withinNoise |
| input/wan150  | input p95 ms  |    171.3 |   170.2 |    -1% | withinNoise |
| photo/lan     | updates/s     |     17.7 |    17.7 |    -0% | withinNoise |
| photo/lan     | bytes/update  |  3038227 | 3038227 |    +0% | withinNoise |
| photo/lan     | CPU ms/update |     8.46 |    8.46 |    -0% | withinNoise |
| photo/lan     | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| photo/wan150  | updates/s     |     2.06 |    2.06 |    -0% | withinNoise |
| photo/wan150  | bytes/update  |  3038226 | 3038226 |    +0% | withinNoise |
| photo/wan150  | CPU ms/update |     20.7 |    20.4 |    -1% | withinNoise |
| photo/wan150  | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/lan    | updates/s     |     64.0 |    64.8 |    +1% | withinNoise |
| scroll/lan    | bytes/update  |    40689 |   40689 |    +0% | withinNoise |
| scroll/lan    | CPU ms/update |     1.04 |    1.05 |    +1% | withinNoise |
| scroll/lan    | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/wan150 | updates/s     |     53.2 |    53.2 |    +0% | withinNoise |
| scroll/wan150 | bytes/update  |    40732 |   40732 |    +0% | withinNoise |
| scroll/wan150 | CPU ms/update |     1.65 |    1.56 |    -5% | withinNoise |
| scroll/wan150 | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| typing/lan    | updates/s     |     63.5 |    65.6 |    +3% | withinNoise |
| typing/lan    | bytes/update  |     63.8 |    63.8 |    +0% | withinNoise |
| typing/lan    | CPU ms/update |     0.63 |    0.67 |    +7% | withinNoise |
| typing/lan    | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| typing/wan150 | updates/s     |     52.9 |    55.2 |    +4% | withinNoise |
| typing/wan150 | bytes/update  |     63.6 |    63.6 |    +0% | withinNoise |
| typing/wan150 | CPU ms/update |     0.85 |    0.85 |    -1% | withinNoise |
| typing/wan150 | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
