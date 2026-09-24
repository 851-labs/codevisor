# 851-2340 — vnc:validate

Build `9e2f2bec0f28+dirty` on Mac16,6. Verdict: **PASS**.

| Layer   | Result |  Time | Summary                                                                                                             |
| ------- | ------ | ----: | ------------------------------------------------------------------------------------------------------------------- |
| tests   | pass   |  21 s | packages/swift (RFB\|VNC\|ScreenSharingDiagnostics\|ScreenSharingViewerEndpoint): 329 tests; rig package: 102 tests |
| interop | pass   |  16 s | vnc:interop: PASS — 10 test(s) ran, 0 skipped                                                                       |
| bench   | pass   | 455 s | vnc-bench: no regression beyond the noise band                                                                      |
| tophat  | pass   |  27 s | vnc:tophat: PASS — 24/24 steps.                                                                                     |

## bench

Machine: Mac16,6, macOS 27.2, AC, load 2.3. Build: `9e2f2bec0f28+dirty`.

Median of 3 run(s) per case; ± is the noise band (largest run deviation).

| scene  | profile | updates/s | input p50 ms | input p95 ms | bytes/update |    Mbit/s | CPU ms/update | copied/update | link est. Mbit/s |
| ------ | ------- | --------: | -----------: | -----------: | -----------: | --------: | ------------: | ------------: | ---------------: |
| typing | lan     |  61.7 ±1% |            – |            – |     44.3 ±0% |  0.02 ±1% |      0.57 ±9% |    103149 ±0% |                – |
| typing | wan150  |  53.6 ±2% |            – |            – |     44.2 ±0% |  0.02 ±2% |      0.65 ±3% |    103149 ±0% |                – |
| scroll | lan     |  61.7 ±0% |            – |            – |    40696 ±0% |  20.1 ±0% |      1.74 ±2% |   4096000 ±0% |                – |
| scroll | wan150  |  52.7 ±1% |            – |            – |    40736 ±0% |  17.2 ±1% |      2.14 ±2% |   4096000 ±0% |                – |
| photo  | lan     |  18.6 ±0% |            – |            – |  2923576 ±0% | 434.6 ±0% |      9.11 ±1% |   4096000 ±0% |        489.9 ±1% |
| photo  | wan150  |  2.14 ±0% |            – |            – |  2923587 ±0% |  50.0 ±0% |      21.8 ±5% |   4096000 ±0% |         45.6 ±1% |
| input  | lan     |         – |     3.36 ±1% |     3.54 ±4% |            – |         – |             – |             – |                – |
| input  | wan150  |         – |    160.2 ±1% |    168.6 ±0% |            – |         – |             – |             – |                – |

## Against /Users/alexandru/codevisor/c1c03091-66c4-4d69-808e-48293c61de1e/currant/tmp/vnc-bench/2026-09-24T021334Z/main/bench.json (build `main 5e3d2d8b755d`)

| case          | metric        | baseline | current | change | verdict     |
| ------------- | ------------- | -------: | ------: | -----: | ----------- |
| input/lan     | input p50 ms  |     3.23 |    3.36 |    +4% | withinNoise |
| input/lan     | input p95 ms  |     3.29 |    3.54 |    +7% | withinNoise |
| input/wan150  | input p50 ms  |    161.9 |   160.2 |    -1% | withinNoise |
| input/wan150  | input p95 ms  |    169.9 |   168.6 |    -1% | withinNoise |
| photo/lan     | updates/s     |     18.3 |    18.6 |    +2% | withinNoise |
| photo/lan     | bytes/update  |  2923576 | 2923576 |    +0% | withinNoise |
| photo/lan     | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| photo/wan150  | updates/s     |     2.14 |    2.14 |    +0% | withinNoise |
| photo/wan150  | bytes/update  |  2923587 | 2923587 |    +0% | withinNoise |
| photo/wan150  | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/lan    | updates/s     |     61.4 |    61.7 |    +0% | withinNoise |
| scroll/lan    | bytes/update  |    40696 |   40696 |    +0% | withinNoise |
| scroll/lan    | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/wan150 | updates/s     |     52.0 |    52.7 |    +1% | withinNoise |
| scroll/wan150 | bytes/update  |    40736 |   40736 |    +0% | withinNoise |
| scroll/wan150 | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| typing/lan    | updates/s     |     62.4 |    61.7 |    -1% | withinNoise |
| typing/lan    | bytes/update  |     44.3 |    44.3 |    +0% | withinNoise |
| typing/lan    | copied/update |   103149 |  103149 |    +0% | withinNoise |
| typing/wan150 | updates/s     |     53.6 |    53.6 |    -0% | withinNoise |
| typing/wan150 | bytes/update  |     44.2 |    44.2 |    +0% | withinNoise |
| typing/wan150 | copied/update |   103149 |  103149 |    +0% | withinNoise |
