# 851-2318 — vnc:validate

Build `e952d23ecabb+dirty` on Mac16,6. Verdict: **PASS**.

| Layer   | Result |  Time | Summary                                                                                                            |
| ------- | ------ | ----: | ------------------------------------------------------------------------------------------------------------------ |
| tests   | pass   |  22 s | packages/swift (RFB\|VNC\|ScreenSharingDiagnostics\|ScreenSharingViewerEndpoint): 316 tests; rig package: 92 tests |
| interop | pass   |  13 s | vnc:interop: PASS — 9 test(s) ran, 0 skipped                                                                       |
| bench   | pass   | 406 s | vnc-bench: no regression beyond the noise band                                                                     |
| tophat  | pass   |  26 s | vnc:tophat: PASS — 24/24 steps.                                                                                    |

## bench

Machine: Mac16,6, macOS 27.2, AC, load 2.6. Build: `e952d23ecabb+dirty`.

Median of 3 run(s) per case; ± is the noise band (largest run deviation).

| scene  | profile | updates/s | input p50 ms | input p95 ms | bytes/update |    Mbit/s | CPU ms/update | copied/update |
| ------ | ------- | --------: | -----------: | -----------: | -----------: | --------: | ------------: | ------------: |
| typing | lan     |  62.1 ±0% |            – |            – |     44.3 ±0% |  0.02 ±0% |     0.57 ±12% |    103149 ±0% |
| typing | wan150  |  53.4 ±2% |            – |            – |     44.2 ±0% |  0.02 ±2% |      0.64 ±3% |    103149 ±0% |
| scroll | lan     |  61.5 ±0% |            – |            – |    40696 ±0% |  20.0 ±0% |      1.82 ±4% |   4096000 ±0% |
| scroll | wan150  |  52.2 ±2% |            – |            – |    40736 ±0% |  17.0 ±2% |     1.18 ±83% |   4096000 ±0% |
| photo  | lan     |  18.6 ±2% |            – |            – |  2923576 ±0% | 434.1 ±2% |      9.00 ±2% |   4096000 ±0% |
| photo  | wan150  |  2.14 ±0% |            – |            – |  2923587 ±0% |  50.0 ±0% |      21.0 ±5% |   4096000 ±0% |
| input  | lan     |         – |     3.38 ±4% |    3.78 ±10% |            – |         – |             – |             – |
| input  | wan150  |         – |    161.3 ±1% |    171.5 ±2% |            – |         – |             – |             – |

## Against /Users/alexandru/codevisor/c1c03091-66c4-4d69-808e-48293c61de1e/currant/tmp/vnc-bench/2026-09-23T112209Z/main/bench.json (build `main e952d23ecabb`)

| case          | metric        | baseline | current | change | verdict     |
| ------------- | ------------- | -------: | ------: | -----: | ----------- |
| input/lan     | input p50 ms  |     3.38 |    3.38 |    +0% | withinNoise |
| input/lan     | input p95 ms  |     3.49 |    3.78 |    +8% | withinNoise |
| input/wan150  | input p50 ms  |    161.2 |   161.3 |    +0% | withinNoise |
| input/wan150  | input p95 ms  |    169.5 |   171.5 |    +1% | withinNoise |
| photo/lan     | updates/s     |     18.6 |    18.6 |    -0% | withinNoise |
| photo/lan     | bytes/update  |  2923576 | 2923576 |    +0% | withinNoise |
| photo/lan     | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| photo/wan150  | updates/s     |     2.14 |    2.14 |    +0% | withinNoise |
| photo/wan150  | bytes/update  |  2923587 | 2923587 |    +0% | withinNoise |
| photo/wan150  | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/lan    | updates/s     |     61.4 |    61.5 |    +0% | withinNoise |
| scroll/lan    | bytes/update  |    40696 |   40696 |    +0% | withinNoise |
| scroll/lan    | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/wan150 | updates/s     |     52.5 |    52.2 |    -1% | withinNoise |
| scroll/wan150 | bytes/update  |    40736 |   40736 |    +0% | withinNoise |
| scroll/wan150 | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| typing/lan    | updates/s     |     62.3 |    62.1 |    -0% | withinNoise |
| typing/lan    | bytes/update  |     44.3 |    44.3 |    +0% | withinNoise |
| typing/lan    | copied/update |   103149 |  103149 |    +0% | withinNoise |
| typing/wan150 | updates/s     |     52.7 |    53.4 |    +1% | withinNoise |
| typing/wan150 | bytes/update  |     44.2 |    44.2 |    +0% | withinNoise |
| typing/wan150 | copied/update |   103149 |  103149 |    +0% | withinNoise |
