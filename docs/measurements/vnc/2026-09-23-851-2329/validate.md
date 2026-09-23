# 851-2329 — vnc:validate

Build `384eee538360+dirty` on Mac16,6. Verdict: **PASS**.

| Layer   | Result |  Time | Summary                                                                                                            |
| ------- | ------ | ----: | ------------------------------------------------------------------------------------------------------------------ |
| tests   | pass   |  18 s | packages/swift (RFB\|VNC\|ScreenSharingDiagnostics\|ScreenSharingViewerEndpoint): 321 tests; rig package: 92 tests |
| interop | pass   |  15 s | vnc:interop: PASS — 10 test(s) ran, 0 skipped                                                                      |
| bench   | pass   | 433 s | vnc-bench: no regression beyond the noise band                                                                     |
| tophat  | pass   |  26 s | vnc:tophat: PASS — 24/24 steps.                                                                                    |

## bench

Machine: Mac16,6, macOS 27.2, AC, load 4.6. Build: `384eee538360+dirty`.

Median of 3 run(s) per case; ± is the noise band (largest run deviation).

| scene  | profile | updates/s | input p50 ms | input p95 ms | bytes/update |    Mbit/s | CPU ms/update | copied/update |
| ------ | ------- | --------: | -----------: | -----------: | -----------: | --------: | ------------: | ------------: |
| typing | lan     |  62.1 ±1% |            – |            – |     44.3 ±0% |  0.02 ±1% |      0.66 ±1% |    103149 ±0% |
| typing | wan150  |  54.1 ±1% |            – |            – |     44.2 ±0% |  0.02 ±1% |      0.82 ±4% |    103149 ±0% |
| scroll | lan     |  61.7 ±0% |            – |            – |    40696 ±0% |  20.1 ±0% |      1.91 ±7% |   4096000 ±0% |
| scroll | wan150  |  53.3 ±1% |            – |            – |    40736 ±0% |  17.4 ±1% |      2.16 ±3% |   4096000 ±0% |
| photo  | lan     |  18.8 ±0% |            – |            – |  2923576 ±0% | 438.8 ±0% |      8.89 ±1% |   4096000 ±0% |
| photo  | wan150  |  2.14 ±0% |            – |            – |  2923587 ±0% |  50.0 ±0% |      20.9 ±3% |   4096000 ±0% |
| input  | lan     |         – |     3.35 ±2% |     3.55 ±6% |            – |         – |             – |             – |
| input  | wan150  |         – |    155.6 ±1% |    165.4 ±0% |            – |         – |             – |             – |

## Against /Users/alexandru/codevisor/c1c03091-66c4-4d69-808e-48293c61de1e/currant/tmp/vnc-bench/2026-09-23T173148Z/main/bench.json (build `main 384eee538360`)

| case          | metric        | baseline | current | change | verdict     |
| ------------- | ------------- | -------: | ------: | -----: | ----------- |
| input/lan     | input p50 ms  |     3.33 |    3.35 |    +1% | withinNoise |
| input/lan     | input p95 ms  |     3.53 |    3.55 |    +1% | withinNoise |
| input/wan150  | input p50 ms  |    155.4 |   155.6 |    +0% | withinNoise |
| input/wan150  | input p95 ms  |    165.7 |   165.4 |    -0% | withinNoise |
| photo/lan     | updates/s     |     18.2 |    18.8 |    +3% | withinNoise |
| photo/lan     | bytes/update  |  2923576 | 2923576 |    +0% | withinNoise |
| photo/lan     | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| photo/wan150  | updates/s     |     2.14 |    2.14 |    +0% | withinNoise |
| photo/wan150  | bytes/update  |  2923587 | 2923587 |    +0% | withinNoise |
| photo/wan150  | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/lan    | updates/s     |     61.9 |    61.7 |    -0% | withinNoise |
| scroll/lan    | bytes/update  |    40696 |   40696 |    +0% | withinNoise |
| scroll/lan    | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/wan150 | updates/s     |     51.3 |    53.3 |    +4% | withinNoise |
| scroll/wan150 | bytes/update  |    40736 |   40736 |    +0% | withinNoise |
| scroll/wan150 | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| typing/lan    | updates/s     |     62.1 |    62.1 |    +0% | withinNoise |
| typing/lan    | bytes/update  |     44.3 |    44.3 |    +0% | withinNoise |
| typing/lan    | copied/update |   103149 |  103149 |    +0% | withinNoise |
| typing/wan150 | updates/s     |     52.9 |    54.1 |    +2% | withinNoise |
| typing/wan150 | bytes/update  |     44.2 |    44.2 |    +0% | withinNoise |
| typing/wan150 | copied/update |   103149 |  103149 |    +0% | withinNoise |
