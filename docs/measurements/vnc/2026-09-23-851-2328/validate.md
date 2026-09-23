# 851-2328 — vnc:validate

Build `4526b4a0fc10+dirty` on Mac16,6. Verdict: **PASS**.

| Layer   | Result |  Time | Summary                                                                                                            |
| ------- | ------ | ----: | ------------------------------------------------------------------------------------------------------------------ |
| tests   | pass   |  28 s | packages/swift (RFB\|VNC\|ScreenSharingDiagnostics\|ScreenSharingViewerEndpoint): 250 tests; rig package: 92 tests |
| interop | pass   |  10 s | vnc:interop: PASS — 3 test(s) ran, 0 skipped                                                                       |
| bench   | pass   | 324 s | vnc-bench: no regression beyond the noise band                                                                     |
| tophat  | pass   |  29 s | vnc:tophat: PASS — 24/24 steps.                                                                                    |

## bench

Machine: Mac16,6, macOS 27.2, AC, load 2.5. Build: `4526b4a0fc10+dirty`.

Median of 3 run(s) per case; ± is the noise band (largest run deviation).

| scene  | profile | updates/s | update p50 ms | update p95 ms | input p50 ms | input p95 ms | bytes/update |    Mbit/s | CPU ms/update | copied/update |
| ------ | ------- | --------: | ------------: | ------------: | -----------: | -----------: | -----------: | --------: | ------------: | ------------: |
| typing | lan     | 297.8 ±2% |      3.33 ±3% |      3.38 ±1% |            – |            – |     63.8 ±0% |  0.15 ±2% |     0.36 ±24% |   4096000 ±0% |
| typing | wan150  |  6.31 ±0% |     157.5 ±0% |     165.5 ±0% |            – |            – |     63.8 ±0% |  0.00 ±0% |      1.58 ±5% |   4096000 ±0% |
| scroll | lan     | 190.7 ±5% |      5.00 ±6% |      5.90 ±5% |            – |            – |    40689 ±0% |  62.1 ±5% |      0.69 ±5% |   4096000 ±0% |
| scroll | wan150  |  5.85 ±1% |     169.5 ±1% |     179.1 ±1% |            – |            – |    40689 ±0% |  1.90 ±1% |     2.52 ±17% |   4096000 ±0% |
| photo  | lan     |  15.3 ±0% |      65.4 ±0% |      66.5 ±0% |            – |            – |  3038227 ±0% | 370.7 ±0% |      8.12 ±2% |   4096000 ±0% |
| photo  | wan150  |  1.35 ±1% |     741.9 ±1% |     764.4 ±0% |            – |            – |  3038227 ±0% |  32.8 ±1% |      26.0 ±5% |   4096000 ±0% |
| input  | lan     |         – |             – |             – |     3.28 ±6% |     3.51 ±5% |            – |         – |             – |             – |
| input  | wan150  |         – |             – |             – |    158.5 ±0% |    167.1 ±1% |            – |         – |             – |             – |

## Against /Users/alexandru/codevisor/c1c03091-66c4-4d69-808e-48293c61de1e/currant/docs/measurements/vnc/baseline-Mac16_6.json (build `d070e5249584+dirty`)

| case          | metric        | baseline | current | change | verdict     |
| ------------- | ------------- | -------: | ------: | -----: | ----------- |
| input/lan     | input p50 ms  |     3.50 |    3.28 |    -6% | withinNoise |
| input/lan     | input p95 ms  |     3.53 |    3.51 |    -1% | withinNoise |
| input/wan150  | input p50 ms  |    158.9 |   158.5 |    -0% | withinNoise |
| input/wan150  | input p95 ms  |    166.1 |   167.1 |    +1% | withinNoise |
| photo/lan     | updates/s     |     15.4 |    15.3 |    -1% | withinNoise |
| photo/lan     | update p50 ms |     64.7 |    65.4 |    +1% | withinNoise |
| photo/lan     | update p95 ms |     65.8 |    66.5 |    +1% | withinNoise |
| photo/lan     | bytes/update  |  3038227 | 3038227 |    +0% | withinNoise |
| photo/lan     | CPU ms/update |     8.05 |    8.12 |    +1% | withinNoise |
| photo/lan     | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| photo/wan150  | updates/s     |     1.32 |    1.35 |    +2% | withinNoise |
| photo/wan150  | update p50 ms |    759.3 |   741.9 |    -2% | withinNoise |
| photo/wan150  | update p95 ms |    770.9 |   764.4 |    -1% | withinNoise |
| photo/wan150  | bytes/update  |  3038227 | 3038227 |    +0% | withinNoise |
| photo/wan150  | CPU ms/update |     30.2 |    26.0 |   -14% | withinNoise |
| photo/wan150  | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/lan    | updates/s     |    180.4 |   190.7 |    +6% | withinNoise |
| scroll/lan    | update p50 ms |     5.25 |    5.00 |    -5% | withinNoise |
| scroll/lan    | update p95 ms |     6.44 |    5.90 |    -8% | withinNoise |
| scroll/lan    | bytes/update  |    40689 |   40689 |    +0% | withinNoise |
| scroll/lan    | CPU ms/update |     0.75 |    0.69 |    -9% | withinNoise |
| scroll/lan    | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/wan150 | updates/s     |     5.81 |    5.85 |    +1% | withinNoise |
| scroll/wan150 | update p50 ms |    170.7 |   169.5 |    -1% | withinNoise |
| scroll/wan150 | update p95 ms |    179.9 |   179.1 |    -0% | withinNoise |
| scroll/wan150 | bytes/update  |    40689 |   40689 |    +0% | withinNoise |
| scroll/wan150 | CPU ms/update |     2.86 |    2.52 |   -12% | withinNoise |
| scroll/wan150 | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| typing/lan    | updates/s     |    288.7 |   297.8 |    +3% | withinNoise |
| typing/lan    | update p50 ms |     3.34 |    3.33 |    -0% | withinNoise |
| typing/lan    | update p95 ms |     3.40 |    3.38 |    -0% | withinNoise |
| typing/lan    | bytes/update  |     63.8 |    63.8 |    +0% | withinNoise |
| typing/lan    | CPU ms/update |     0.40 |    0.36 |   -11% | withinNoise |
| typing/lan    | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| typing/wan150 | updates/s     |     6.33 |    6.31 |    -0% | withinNoise |
| typing/wan150 | update p50 ms |    156.4 |   157.5 |    +1% | withinNoise |
| typing/wan150 | update p95 ms |    164.5 |   165.5 |    +1% | withinNoise |
| typing/wan150 | bytes/update  |     63.8 |    63.8 |    +0% | withinNoise |
| typing/wan150 | CPU ms/update |     1.73 |    1.58 |    -9% | withinNoise |
| typing/wan150 | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
