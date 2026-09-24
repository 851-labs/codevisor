# 851-2336 — vnc:validate

Build `b7637dca88a8+dirty` on Mac16,6. Verdict: **PASS**.

| Layer   | Result |  Time | Summary                                                                                                             |
| ------- | ------ | ----: | ------------------------------------------------------------------------------------------------------------------- |
| tests   | pass   |  27 s | packages/swift (RFB\|VNC\|ScreenSharingDiagnostics\|ScreenSharingViewerEndpoint): 325 tests; rig package: 102 tests |
| interop | pass   |  16 s | vnc:interop: PASS — 10 test(s) ran, 0 skipped                                                                       |
| bench   | pass   | 410 s | vnc-bench: no regression beyond the noise band                                                                      |
| tophat  | pass   |  28 s | vnc:tophat: PASS — 24/24 steps.                                                                                     |

## bench

Machine: Mac16,6, macOS 27.2, AC, load 3.1. Build: `b7637dca88a8+dirty`.

Median of 3 run(s) per case; ± is the noise band (largest run deviation).

| scene  | profile | updates/s | input p50 ms | input p95 ms | bytes/update |    Mbit/s | CPU ms/update | copied/update | link est. Mbit/s |
| ------ | ------- | --------: | -----------: | -----------: | -----------: | --------: | ------------: | ------------: | ---------------: |
| typing | lan     |  62.3 ±0% |            – |            – |     44.3 ±0% |  0.02 ±0% |      0.73 ±5% |    103149 ±0% |                – |
| typing | wan150  |  53.3 ±2% |            – |            – |     44.2 ±0% |  0.02 ±2% |      0.82 ±9% |    103149 ±0% |                – |
| scroll | lan     |  61.5 ±0% |            – |            – |    40696 ±0% |  20.0 ±0% |      1.81 ±7% |   4096000 ±0% |                – |
| scroll | wan150  |  52.3 ±2% |            – |            – |    40736 ±0% |  17.1 ±2% |     2.25 ±39% |   4096000 ±0% |                – |
| photo  | lan     |  18.6 ±0% |            – |            – |  2923576 ±0% | 434.6 ±0% |      9.11 ±0% |   4096000 ±0% |        484.0 ±5% |
| photo  | wan150  |  2.14 ±0% |            – |            – |  2923587 ±0% |  50.0 ±0% |      21.9 ±3% |   4096000 ±0% |         46.5 ±1% |
| input  | lan     |         – |     3.36 ±1% |     3.66 ±8% |            – |         – |             – |             – |                – |
| input  | wan150  |         – |    160.3 ±0% |    168.9 ±1% |            – |         – |             – |             – |                – |

## Against /Users/alexandru/codevisor/c1c03091-66c4-4d69-808e-48293c61de1e/currant/tmp/vnc-bench/2026-09-23T235528Z/main/bench.json (build `main b7637dca88a8`)

| case          | metric        | baseline | current | change | verdict     |
| ------------- | ------------- | -------: | ------: | -----: | ----------- |
| input/lan     | input p50 ms  |     3.40 |    3.36 |    -1% | withinNoise |
| input/lan     | input p95 ms  |     3.77 |    3.66 |    -3% | withinNoise |
| input/wan150  | input p50 ms  |    160.7 |   160.3 |    -0% | withinNoise |
| input/wan150  | input p95 ms  |    171.9 |   168.9 |    -2% | withinNoise |
| photo/lan     | updates/s     |     18.5 |    18.6 |    +0% | withinNoise |
| photo/lan     | bytes/update  |  2923576 | 2923576 |    +0% | withinNoise |
| photo/lan     | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| photo/wan150  | updates/s     |     2.14 |    2.14 |    -0% | withinNoise |
| photo/wan150  | bytes/update  |  2923587 | 2923587 |    +0% | withinNoise |
| photo/wan150  | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/lan    | updates/s     |     61.5 |    61.5 |    -0% | withinNoise |
| scroll/lan    | bytes/update  |    40696 |   40696 |    +0% | withinNoise |
| scroll/lan    | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/wan150 | updates/s     |     51.9 |    52.3 |    +1% | withinNoise |
| scroll/wan150 | bytes/update  |    40736 |   40736 |    +0% | withinNoise |
| scroll/wan150 | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| typing/lan    | updates/s     |     62.4 |    62.3 |    -0% | withinNoise |
| typing/lan    | bytes/update  |     44.3 |    44.3 |    +0% | withinNoise |
| typing/lan    | copied/update |   103149 |  103149 |    +0% | withinNoise |
| typing/wan150 | updates/s     |     53.5 |    53.3 |    -0% | withinNoise |
| typing/wan150 | bytes/update  |     44.2 |    44.2 |    +0% | withinNoise |
| typing/wan150 | copied/update |   103149 |  103149 |    +0% | withinNoise |
