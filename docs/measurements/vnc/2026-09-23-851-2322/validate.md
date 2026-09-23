# 851-2322 — vnc:validate

Build `d2733b676ac0+dirty` on Mac16,6. Verdict: **PASS**.

| Layer   | Result |  Time | Summary                                                                                                            |
| ------- | ------ | ----: | ------------------------------------------------------------------------------------------------------------------ |
| tests   | pass   |  29 s | packages/swift (RFB\|VNC\|ScreenSharingDiagnostics\|ScreenSharingViewerEndpoint): 317 tests; rig package: 92 tests |
| interop | pass   |  15 s | vnc:interop: PASS — 10 test(s) ran, 0 skipped                                                                      |
| bench   | pass   | 400 s | vnc-bench: no regression beyond the noise band                                                                     |
| tophat  | pass   |  25 s | vnc:tophat: PASS — 24/24 steps.                                                                                    |

## bench

Machine: Mac16,6, macOS 27.2, AC, load 3.2. Build: `d2733b676ac0+dirty`.

Median of 3 run(s) per case; ± is the noise band (largest run deviation).

| scene  | profile | updates/s | input p50 ms | input p95 ms | bytes/update |    Mbit/s | CPU ms/update | copied/update |
| ------ | ------- | --------: | -----------: | -----------: | -----------: | --------: | ------------: | ------------: |
| typing | lan     |  62.1 ±0% |            – |            – |     44.3 ±0% |  0.02 ±0% |     0.55 ±16% |    103149 ±0% |
| typing | wan150  |  51.4 ±5% |            – |            – |     44.2 ±0% |  0.02 ±5% |     0.56 ±47% |    103149 ±0% |
| scroll | lan     |  61.4 ±1% |            – |            – |    40696 ±0% |  20.0 ±1% |      1.73 ±7% |   4096000 ±0% |
| scroll | wan150  |  52.7 ±2% |            – |            – |    40736 ±0% |  17.2 ±2% |      2.07 ±2% |   4096000 ±0% |
| photo  | lan     |  18.9 ±2% |            – |            – |  2923576 ±0% | 442.8 ±2% |      8.78 ±2% |   4096000 ±0% |
| photo  | wan150  |  2.14 ±0% |            – |            – |  2923587 ±0% |  50.0 ±0% |      20.1 ±6% |   4096000 ±0% |
| input  | lan     |         – |     3.37 ±0% |     3.74 ±9% |            – |         – |             – |             – |
| input  | wan150  |         – |    160.3 ±1% |    170.7 ±0% |            – |         – |             – |             – |

## Against /Users/alexandru/codevisor/c1c03091-66c4-4d69-808e-48293c61de1e/currant/tmp/vnc-bench/2026-09-23T153802Z/main/bench.json (build `main d2733b676ac0`)

| case          | metric        | baseline | current | change | verdict     |
| ------------- | ------------- | -------: | ------: | -----: | ----------- |
| input/lan     | input p50 ms  |     3.39 |    3.37 |    -1% | withinNoise |
| input/lan     | input p95 ms  |     3.56 |    3.74 |    +5% | withinNoise |
| input/wan150  | input p50 ms  |    155.7 |   160.3 |    +3% | withinNoise |
| input/wan150  | input p95 ms  |    164.6 |   170.7 |    +4% | withinNoise |
| photo/lan     | updates/s     |     18.7 |    18.9 |    +1% | withinNoise |
| photo/lan     | bytes/update  |  2923576 | 2923576 |    +0% | withinNoise |
| photo/lan     | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| photo/wan150  | updates/s     |     2.14 |    2.14 |    +0% | withinNoise |
| photo/wan150  | bytes/update  |  2923587 | 2923587 |    +0% | withinNoise |
| photo/wan150  | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/lan    | updates/s     |     61.6 |    61.4 |    -0% | withinNoise |
| scroll/lan    | bytes/update  |    40696 |   40696 |    +0% | withinNoise |
| scroll/lan    | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/wan150 | updates/s     |     52.1 |    52.7 |    +1% | withinNoise |
| scroll/wan150 | bytes/update  |    40736 |   40736 |    +0% | withinNoise |
| scroll/wan150 | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| typing/lan    | updates/s     |     62.3 |    62.1 |    -0% | withinNoise |
| typing/lan    | bytes/update  |     44.3 |    44.3 |    +0% | withinNoise |
| typing/lan    | copied/update |   103149 |  103149 |    +0% | withinNoise |
| typing/wan150 | updates/s     |     53.3 |    51.4 |    -4% | withinNoise |
| typing/wan150 | bytes/update  |     44.2 |    44.2 |    +0% | withinNoise |
| typing/wan150 | copied/update |   103149 |  103149 |    +0% | withinNoise |
