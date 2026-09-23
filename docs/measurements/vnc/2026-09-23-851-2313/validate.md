# 851-2313 — vnc:validate

Build `c9ebe60f1680+dirty` on Mac16,6. Verdict: **PASS**.

| Layer   | Result |  Time | Summary                                                                                                            |
| ------- | ------ | ----: | ------------------------------------------------------------------------------------------------------------------ |
| tests   | pass   |  26 s | packages/swift (RFB\|VNC\|ScreenSharingDiagnostics\|ScreenSharingViewerEndpoint): 308 tests; rig package: 92 tests |
| interop | pass   |  13 s | vnc:interop: PASS — 8 test(s) ran, 0 skipped                                                                       |
| bench   | pass   | 374 s | vnc-bench: no regression beyond the noise band                                                                     |
| tophat  | pass   |  25 s | vnc:tophat: PASS — 24/24 steps.                                                                                    |

## bench

Machine: Mac16,6, macOS 27.2, AC, load 3.1. Build: `c9ebe60f1680+dirty`.

Median of 3 run(s) per case; ± is the noise band (largest run deviation).

| scene  | profile | updates/s | input p50 ms | input p95 ms | bytes/update |    Mbit/s | CPU ms/update | copied/update |
| ------ | ------- | --------: | -----------: | -----------: | -----------: | --------: | ------------: | ------------: |
| typing | lan     |  61.9 ±0% |            – |            – |     44.3 ±0% |  0.02 ±0% |     0.80 ±14% |   4096000 ±0% |
| typing | wan150  |  52.2 ±1% |            – |            – |     44.2 ±0% |  0.02 ±1% |      0.91 ±4% |   4096000 ±0% |
| scroll | lan     |  61.2 ±1% |            – |            – |    40696 ±0% |  19.9 ±1% |      1.35 ±6% |   4096000 ±0% |
| scroll | wan150  |  52.0 ±1% |            – |            – |    40736 ±0% |  17.0 ±1% |      1.67 ±4% |   4096000 ±0% |
| photo  | lan     |  19.1 ±1% |            – |            – |  2923576 ±0% | 446.6 ±1% |      8.77 ±0% |   4096000 ±0% |
| photo  | wan150  |  2.14 ±0% |            – |            – |  2923587 ±0% |  50.0 ±0% |      20.8 ±4% |   4096000 ±0% |
| input  | lan     |         – |     3.45 ±2% |     3.51 ±7% |            – |         – |             – |             – |
| input  | wan150  |         – |    160.6 ±2% |    170.1 ±2% |            – |         – |             – |             – |

## Against /Users/alexandru/codevisor/c1c03091-66c4-4d69-808e-48293c61de1e/currant/tmp/vnc-bench/2026-09-23T102845Z/main/bench.json (build `main c9ebe60f1680`)

| case          | metric        | baseline | current | change | verdict     |
| ------------- | ------------- | -------: | ------: | -----: | ----------- |
| input/lan     | input p50 ms  |     3.42 |    3.45 |    +1% | withinNoise |
| input/lan     | input p95 ms  |     3.47 |    3.51 |    +1% | withinNoise |
| input/wan150  | input p50 ms  |    163.4 |   160.6 |    -2% | withinNoise |
| input/wan150  | input p95 ms  |    171.2 |   170.1 |    -1% | withinNoise |
| photo/lan     | updates/s     |     17.7 |    19.1 |    +8% | withinNoise |
| photo/lan     | bytes/update  |  3038227 | 2923576 |    -4% | withinNoise |
| photo/lan     | CPU ms/update |     8.44 |    8.77 |    +4% | withinNoise |
| photo/lan     | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| photo/wan150  | updates/s     |     2.06 |    2.14 |    +4% | withinNoise |
| photo/wan150  | bytes/update  |  3038226 | 2923587 |    -4% | withinNoise |
| photo/wan150  | CPU ms/update |     20.4 |    20.8 |    +2% | withinNoise |
| photo/wan150  | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/lan    | updates/s     |     65.3 |    61.2 |    -6% | withinNoise |
| scroll/lan    | bytes/update  |    40689 |   40696 |    +0% | withinNoise |
| scroll/lan    | CPU ms/update |     1.13 |    1.35 |   +20% | withinNoise |
| scroll/lan    | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/wan150 | updates/s     |     53.2 |    52.0 |    -2% | withinNoise |
| scroll/wan150 | bytes/update  |    40732 |   40736 |    +0% | withinNoise |
| scroll/wan150 | CPU ms/update |     1.53 |    1.67 |    +9% | withinNoise |
| scroll/wan150 | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| typing/lan    | updates/s     |     64.8 |    61.9 |    -4% | withinNoise |
| typing/lan    | bytes/update  |     63.8 |    44.3 |   -31% | withinNoise |
| typing/lan    | CPU ms/update |     0.64 |    0.80 |   +26% | withinNoise |
| typing/lan    | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| typing/wan150 | updates/s     |     52.9 |    52.2 |    -1% | withinNoise |
| typing/wan150 | bytes/update  |     63.6 |    44.2 |   -30% | withinNoise |
| typing/wan150 | CPU ms/update |     0.84 |    0.91 |    +9% | withinNoise |
| typing/wan150 | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
