# 851-2320 — vnc:validate

Build `bb5471fd189e+dirty` on Mac16,6. Verdict: **PASS**.

| Layer   | Result |  Time | Summary                                                                                                            |
| ------- | ------ | ----: | ------------------------------------------------------------------------------------------------------------------ |
| tests   | pass   |  18 s | packages/swift (RFB\|VNC\|ScreenSharingDiagnostics\|ScreenSharingViewerEndpoint): 315 tests; rig package: 92 tests |
| interop | pass   |  15 s | vnc:interop: PASS — 8 test(s) ran, 0 skipped                                                                       |
| bench   | pass   | 380 s | vnc-bench: no regression beyond the noise band                                                                     |
| tophat  | pass   |  26 s | vnc:tophat: PASS — 24/24 steps.                                                                                    |

## bench

Machine: Mac16,6, macOS 27.2, AC, load 2.4. Build: `bb5471fd189e+dirty`.

Median of 3 run(s) per case; ± is the noise band (largest run deviation).

| scene  | profile | updates/s | input p50 ms | input p95 ms | bytes/update |    Mbit/s | CPU ms/update | copied/update |
| ------ | ------- | --------: | -----------: | -----------: | -----------: | --------: | ------------: | ------------: |
| typing | lan     |  62.2 ±1% |            – |            – |     44.3 ±0% |  0.02 ±1% |     0.59 ±18% |    103149 ±0% |
| typing | wan150  |  50.7 ±8% |            – |            – |     44.2 ±0% |  0.02 ±8% |    0.27 ±133% |    103149 ±0% |
| scroll | lan     |  61.4 ±0% |            – |            – |    40696 ±0% |  20.0 ±0% |      1.85 ±2% |   4096000 ±0% |
| scroll | wan150  |  51.6 ±3% |            – |            – |    40736 ±0% |  16.8 ±3% |      2.20 ±2% |   4096000 ±0% |
| photo  | lan     |  19.0 ±0% |            – |            – |  2923576 ±0% | 444.9 ±0% |      8.88 ±0% |   4096000 ±0% |
| photo  | wan150  |  2.14 ±0% |            – |            – |  2923587 ±0% |  50.0 ±0% |      20.9 ±6% |   4096000 ±0% |
| input  | lan     |         – |     3.25 ±1% |     3.40 ±3% |            – |         – |             – |             – |
| input  | wan150  |         – |    160.0 ±1% |    169.8 ±0% |            – |         – |             – |             – |

## Against /Users/alexandru/codevisor/c1c03091-66c4-4d69-808e-48293c61de1e/currant/tmp/vnc-bench/2026-09-23T110801Z/main/bench.json (build `main bb5471fd189e`)

| case          | metric        | baseline | current | change | verdict     |
| ------------- | ------------- | -------: | ------: | -----: | ----------- |
| input/lan     | input p50 ms  |     3.37 |    3.25 |    -4% | withinNoise |
| input/lan     | input p95 ms  |     3.46 |    3.40 |    -2% | withinNoise |
| input/wan150  | input p50 ms  |    162.8 |   160.0 |    -2% | withinNoise |
| input/wan150  | input p95 ms  |    171.6 |   169.8 |    -1% | withinNoise |
| photo/lan     | updates/s     |     18.7 |    19.0 |    +2% | withinNoise |
| photo/lan     | bytes/update  |  2923576 | 2923576 |    +0% | withinNoise |
| photo/lan     | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| photo/wan150  | updates/s     |     2.14 |    2.14 |    -0% | withinNoise |
| photo/wan150  | bytes/update  |  2923587 | 2923587 |    +0% | withinNoise |
| photo/wan150  | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/lan    | updates/s     |     61.5 |    61.4 |    -0% | withinNoise |
| scroll/lan    | bytes/update  |    40696 |   40696 |    +0% | withinNoise |
| scroll/lan    | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/wan150 | updates/s     |     52.8 |    51.6 |    -2% | withinNoise |
| scroll/wan150 | bytes/update  |    40736 |   40736 |    +0% | withinNoise |
| scroll/wan150 | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| typing/lan    | updates/s     |     62.3 |    62.2 |    -0% | withinNoise |
| typing/lan    | bytes/update  |     44.3 |    44.3 |    +0% | withinNoise |
| typing/lan    | copied/update |   103149 |  103149 |    +0% | withinNoise |
| typing/wan150 | updates/s     |     52.4 |    50.7 |    -3% | withinNoise |
| typing/wan150 | bytes/update  |     44.2 |    44.2 |    +0% | withinNoise |
| typing/wan150 | copied/update |   103149 |  103149 |    +0% | withinNoise |
