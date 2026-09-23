# 851-2314 — vnc:validate

Build `8a433c671142+dirty` on Mac16,6. Verdict: **PASS**.

| Layer   | Result |  Time | Summary                                                                                                            |
| ------- | ------ | ----: | ------------------------------------------------------------------------------------------------------------------ |
| tests   | pass   |  20 s | packages/swift (RFB\|VNC\|ScreenSharingDiagnostics\|ScreenSharingViewerEndpoint): 279 tests; rig package: 92 tests |
| interop | pass   |  11 s | vnc:interop: PASS — 6 test(s) ran, 0 skipped                                                                       |
| bench   | pass   | 569 s | vnc-bench: no regression beyond the noise band                                                                     |
| tophat  | pass   |  26 s | vnc:tophat: PASS — 24/24 steps.                                                                                    |

## bench

Machine: Mac16,6, macOS 27.2, AC, load 3.6. Build: `8a433c671142+dirty`.

Median of 3 run(s) per case; ± is the noise band (largest run deviation).

| scene  | profile | updates/s | input p50 ms | input p95 ms | bytes/update |    Mbit/s | CPU ms/update | copied/update |
| ------ | ------- | --------: | -----------: | -----------: | -----------: | --------: | ------------: | ------------: |
| typing | lan     |  63.0 ±1% |            – |            – |     63.8 ±0% |  0.03 ±1% |      0.25 ±0% |   4096000 ±0% |
| typing | wan150  |  53.1 ±3% |            – |            – |     63.6 ±0% |  0.03 ±3% |     0.87 ±43% |   4096000 ±0% |
| scroll | lan     |  65.2 ±1% |            – |            – |    40689 ±0% |  21.2 ±1% |      1.12 ±8% |   4096000 ±0% |
| scroll | wan150  |  53.4 ±3% |            – |            – |    40732 ±0% |  17.4 ±3% |     1.53 ±62% |   4096000 ±0% |
| photo  | lan     |  17.8 ±0% |            – |            – |  3038227 ±0% | 433.4 ±0% |      8.33 ±1% |   4096000 ±0% |
| photo  | wan150  |  2.06 ±0% |            – |            – |  3038226 ±0% |  50.0 ±0% |      20.7 ±5% |   4096000 ±0% |
| input  | lan     |         – |     3.43 ±1% |     3.48 ±1% |            – |         – |             – |             – |
| input  | wan150  |         – |    162.9 ±1% |    171.8 ±0% |            – |         – |             – |             – |

## Against /Users/alexandru/codevisor/c1c03091-66c4-4d69-808e-48293c61de1e/currant/tmp/vnc-bench/2026-09-23T084706Z/main/bench.json (build `main 6763d53ef46b`)

| case          | metric        | baseline | current | change | verdict     |
| ------------- | ------------- | -------: | ------: | -----: | ----------- |
| input/lan     | input p50 ms  |     3.43 |    3.43 |    +0% | withinNoise |
| input/lan     | input p95 ms  |     3.48 |    3.48 |    -0% | withinNoise |
| input/wan150  | input p50 ms  |    162.7 |   162.9 |    +0% | withinNoise |
| input/wan150  | input p95 ms  |    172.6 |   171.8 |    -0% | withinNoise |
| photo/lan     | updates/s     |     17.7 |    17.8 |    +1% | withinNoise |
| photo/lan     | bytes/update  |  3038227 | 3038227 |    +0% | withinNoise |
| photo/lan     | CPU ms/update |     8.50 |    8.33 |    -2% | withinNoise |
| photo/lan     | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| photo/wan150  | updates/s     |     2.06 |    2.06 |    -0% | withinNoise |
| photo/wan150  | bytes/update  |  3038226 | 3038226 |    +0% | withinNoise |
| photo/wan150  | CPU ms/update |     20.9 |    20.7 |    -1% | withinNoise |
| photo/wan150  | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/lan    | updates/s     |     65.0 |    65.2 |    +0% | withinNoise |
| scroll/lan    | bytes/update  |    40689 |   40689 |    +0% | withinNoise |
| scroll/lan    | CPU ms/update |     1.10 |    1.12 |    +1% | withinNoise |
| scroll/lan    | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/wan150 | updates/s     |     53.7 |    53.4 |    -1% | withinNoise |
| scroll/wan150 | bytes/update  |    40732 |   40732 |    +0% | withinNoise |
| scroll/wan150 | CPU ms/update |     1.50 |    1.53 |    +2% | withinNoise |
| scroll/wan150 | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| typing/lan    | updates/s     |     65.4 |    63.0 |    -4% | withinNoise |
| typing/lan    | bytes/update  |     63.8 |    63.8 |    +0% | withinNoise |
| typing/lan    | CPU ms/update |     0.64 |    0.25 |   -60% | withinNoise |
| typing/lan    | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| typing/wan150 | updates/s     |     54.2 |    53.1 |    -2% | withinNoise |
| typing/wan150 | bytes/update  |     63.6 |    63.6 |    +0% | withinNoise |
| typing/wan150 | CPU ms/update |     0.84 |    0.87 |    +3% | withinNoise |
| typing/wan150 | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
