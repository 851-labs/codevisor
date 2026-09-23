# 851-2319 — vnc:validate

Build `d9df470cd4a9+dirty` on Mac16,6. Verdict: **PASS**.

| Layer   | Result |  Time | Summary                                                                                                            |
| ------- | ------ | ----: | ------------------------------------------------------------------------------------------------------------------ |
| tests   | pass   |  20 s | packages/swift (RFB\|VNC\|ScreenSharingDiagnostics\|ScreenSharingViewerEndpoint): 313 tests; rig package: 92 tests |
| interop | pass   |  13 s | vnc:interop: PASS — 8 test(s) ran, 0 skipped                                                                       |
| bench   | pass   | 370 s | vnc-bench: no regression beyond the noise band                                                                     |
| tophat  | pass   |  25 s | vnc:tophat: PASS — 24/24 steps.                                                                                    |

## bench

Machine: Mac16,6, macOS 27.2, AC, load 2.4. Build: `d9df470cd4a9+dirty`.

Median of 3 run(s) per case; ± is the noise band (largest run deviation).

| scene  | profile | updates/s | input p50 ms | input p95 ms | bytes/update |    Mbit/s | CPU ms/update | copied/update |
| ------ | ------- | --------: | -----------: | -----------: | -----------: | --------: | ------------: | ------------: |
| typing | lan     |  61.3 ±1% |            – |            – |     44.3 ±0% |  0.02 ±1% |     0.33 ±39% |    103149 ±0% |
| typing | wan150  |  52.4 ±1% |            – |            – |     44.2 ±0% |  0.02 ±1% |     0.57 ±14% |    103149 ±0% |
| scroll | lan     |  61.6 ±1% |            – |            – |    40696 ±0% |  20.1 ±1% |      1.40 ±4% |   4096000 ±0% |
| scroll | wan150  |  51.8 ±2% |            – |            – |    40736 ±0% |  16.9 ±2% |      1.69 ±4% |   4096000 ±0% |
| photo  | lan     |  19.2 ±0% |            – |            – |  2923576 ±0% | 448.5 ±0% |      8.74 ±1% |   4096000 ±0% |
| photo  | wan150  |  2.14 ±0% |            – |            – |  2923587 ±0% |  50.0 ±0% |      20.5 ±6% |   4096000 ±0% |
| input  | lan     |         – |     3.36 ±1% |     3.42 ±2% |            – |         – |             – |             – |
| input  | wan150  |         – |    162.3 ±1% |    171.1 ±1% |            – |         – |             – |             – |

## Against /Users/alexandru/codevisor/c1c03091-66c4-4d69-808e-48293c61de1e/currant/tmp/vnc-bench/2026-09-23T104832Z/main/bench.json (build `main d9df470cd4a9`)

| case          | metric        | baseline | current | change | verdict     |
| ------------- | ------------- | -------: | ------: | -----: | ----------- |
| input/lan     | input p50 ms  |     3.44 |    3.36 |    -2% | withinNoise |
| input/lan     | input p95 ms  |     3.49 |    3.42 |    -2% | withinNoise |
| input/wan150  | input p50 ms  |    164.0 |   162.3 |    -1% | withinNoise |
| input/wan150  | input p95 ms  |    171.2 |   171.1 |    -0% | withinNoise |
| photo/lan     | updates/s     |     18.9 |    19.2 |    +2% | withinNoise |
| photo/lan     | bytes/update  |  2923576 | 2923576 |    +0% | withinNoise |
| photo/lan     | CPU ms/update |     8.90 |    8.74 |    -2% | withinNoise |
| photo/lan     | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| photo/wan150  | updates/s     |     2.14 |    2.14 |    -0% | withinNoise |
| photo/wan150  | bytes/update  |  2923587 | 2923587 |    +0% | withinNoise |
| photo/wan150  | CPU ms/update |     21.0 |    20.5 |    -2% | withinNoise |
| photo/wan150  | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/lan    | updates/s     |     61.8 |    61.6 |    -0% | withinNoise |
| scroll/lan    | bytes/update  |    40696 |   40696 |    +0% | withinNoise |
| scroll/lan    | CPU ms/update |     1.39 |    1.40 |    +1% | withinNoise |
| scroll/lan    | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/wan150 | updates/s     |     51.6 |    51.8 |    +0% | withinNoise |
| scroll/wan150 | bytes/update  |    40736 |   40736 |    +0% | withinNoise |
| scroll/wan150 | CPU ms/update |     1.63 |    1.69 |    +4% | withinNoise |
| scroll/wan150 | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| typing/lan    | updates/s     |     61.8 |    61.3 |    -1% | withinNoise |
| typing/lan    | bytes/update  |     44.3 |    44.3 |    +0% | withinNoise |
| typing/lan    | CPU ms/update |     0.71 |    0.33 |   -53% | withinNoise |
| typing/lan    | copied/update |  4096000 |  103149 |   -97% | improved    |
| typing/wan150 | updates/s     |     51.8 |    52.4 |    +1% | withinNoise |
| typing/wan150 | bytes/update  |     44.2 |    44.2 |    +0% | withinNoise |
| typing/wan150 | CPU ms/update |     0.90 |    0.57 |   -37% | withinNoise |
| typing/wan150 | copied/update |  4096000 |  103149 |   -97% | improved    |
