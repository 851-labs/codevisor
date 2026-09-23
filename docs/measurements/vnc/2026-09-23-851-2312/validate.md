# 851-2312 — vnc:validate

Build `bb6f282f24ed+dirty` on Mac16,6. Verdict: **PASS**.

| Layer   | Result |  Time | Summary                                                                                                            |
| ------- | ------ | ----: | ------------------------------------------------------------------------------------------------------------------ |
| tests   | pass   |  17 s | packages/swift (RFB\|VNC\|ScreenSharingDiagnostics\|ScreenSharingViewerEndpoint): 271 tests; rig package: 92 tests |
| interop | pass   |  13 s | vnc:interop: PASS — 5 test(s) ran, 0 skipped                                                                       |
| bench   | pass   | 262 s | vnc-bench: no regression beyond the noise band                                                                     |
| tophat  | pass   |  25 s | vnc:tophat: PASS — 23/23 steps.                                                                                    |

## bench

Machine: Mac16,6, macOS 27.2, AC, load 3.2. Build: `bb6f282f24ed+dirty`.

Median of 3 run(s) per case; ± is the noise band (largest run deviation).

| scene  | profile | updates/s | input p50 ms | input p95 ms | bytes/update |    Mbit/s | CPU ms/update | copied/update |
| ------ | ------- | --------: | -----------: | -----------: | -----------: | --------: | ------------: | ------------: |
| typing | lan     |  64.1 ±2% |            – |            – |     63.8 ±0% |  0.03 ±2% |     0.62 ±14% |   4096000 ±0% |
| typing | wan150  |  53.2 ±2% |            – |            – |     63.6 ±0% |  0.03 ±2% |      0.89 ±5% |   4096000 ±0% |
| scroll | lan     |  65.0 ±2% |            – |            – |    40689 ±0% |  21.2 ±2% |     0.57 ±99% |   4096000 ±0% |
| scroll | wan150  |  54.1 ±4% |            – |            – |    40732 ±0% |  17.6 ±4% |      1.59 ±9% |   4096000 ±0% |
| photo  | lan     |  17.8 ±0% |            – |            – |  3038227 ±0% | 432.6 ±0% |      8.38 ±0% |   4096000 ±0% |
| photo  | wan150  |  2.06 ±0% |            – |            – |  3038226 ±0% |  50.0 ±0% |      20.8 ±5% |   4096000 ±0% |
| input  | lan     |         – |     3.42 ±0% |     3.47 ±1% |            – |         – |             – |             – |
| input  | wan150  |         – |    163.7 ±1% |    170.3 ±0% |            – |         – |             – |             – |

## Against /Users/alexandru/codevisor/c1c03091-66c4-4d69-808e-48293c61de1e/currant/docs/measurements/vnc/baseline-Mac16_6.json (build `0b8ba6bd518b+dirty`)

| case          | metric        | baseline | current | change | verdict     |
| ------------- | ------------- | -------: | ------: | -----: | ----------- |
| input/lan     | input p50 ms  |     3.42 |    3.42 |    -0% | withinNoise |
| input/lan     | input p95 ms  |     3.54 |    3.47 |    -2% | withinNoise |
| input/wan150  | input p50 ms  |    163.7 |   163.7 |    -0% | withinNoise |
| input/wan150  | input p95 ms  |    170.1 |   170.3 |    +0% | withinNoise |
| photo/lan     | updates/s     |     15.5 |    17.8 |   +15% | improved    |
| photo/lan     | bytes/update  |  3038227 | 3038227 |    +0% | withinNoise |
| photo/lan     | CPU ms/update |     8.25 |    8.38 |    +2% | withinNoise |
| photo/lan     | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| photo/wan150  | updates/s     |     1.34 |    2.06 |   +54% | improved    |
| photo/wan150  | bytes/update  |  3038226 | 3038226 |    +0% | withinNoise |
| photo/wan150  | CPU ms/update |     27.6 |    20.8 |   -25% | withinNoise |
| photo/wan150  | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/lan    | updates/s     |     61.4 |    65.0 |    +6% | withinNoise |
| scroll/lan    | bytes/update  |    40689 |   40689 |    +0% | withinNoise |
| scroll/lan    | CPU ms/update |     1.36 |    0.57 |   -58% | withinNoise |
| scroll/lan    | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/wan150 | updates/s     |     5.79 |    54.1 |  +834% | improved    |
| scroll/wan150 | bytes/update  |    40732 |   40732 |    +0% | withinNoise |
| scroll/wan150 | CPU ms/update |     2.53 |    1.59 |   -37% | improved    |
| scroll/wan150 | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| typing/lan    | updates/s     |     61.2 |    64.1 |    +5% | withinNoise |
| typing/lan    | bytes/update  |     63.8 |    63.8 |    +0% | withinNoise |
| typing/lan    | CPU ms/update |     0.47 |    0.62 |   +33% | withinNoise |
| typing/lan    | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| typing/wan150 | updates/s     |     6.16 |    53.2 |  +763% | improved    |
| typing/wan150 | bytes/update  |     63.6 |    63.6 |    +0% | withinNoise |
| typing/wan150 | CPU ms/update |     1.54 |    0.89 |   -42% | improved    |
| typing/wan150 | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
