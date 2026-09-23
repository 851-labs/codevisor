# 851-2311 — vnc:validate

Build `788d7cb88cc4+dirty` on Mac16,6. Verdict: **PASS**.

| Layer   | Result |  Time | Summary                                                                                                            |
| ------- | ------ | ----: | ------------------------------------------------------------------------------------------------------------------ |
| tests   | pass   |  21 s | packages/swift (RFB\|VNC\|ScreenSharingDiagnostics\|ScreenSharingViewerEndpoint): 260 tests; rig package: 92 tests |
| interop | pass   |  10 s | vnc:interop: PASS — 4 test(s) ran, 0 skipped                                                                       |
| bench   | pass   | 333 s | vnc-bench: no regression beyond the noise band                                                                     |
| tophat  | pass   |  25 s | vnc:tophat: PASS — 24/24 steps.                                                                                    |

## bench

Machine: Mac16,6, macOS 27.2, AC, load 2.3. Build: `788d7cb88cc4+dirty`.

Median of 3 run(s) per case; ± is the noise band (largest run deviation).

| scene  | profile | updates/s | update p50 ms | update p95 ms | input p50 ms | input p95 ms | bytes/update |    Mbit/s | CPU ms/update | copied/update |
| ------ | ------- | --------: | ------------: | ------------: | -----------: | -----------: | -----------: | --------: | ------------: | ------------: |
| typing | lan     | 295.8 ±1% |      3.32 ±1% |      3.38 ±0% |            – |            – |     63.8 ±0% |  0.15 ±1% |      0.35 ±9% |   4096000 ±0% |
| typing | wan150  |  6.08 ±0% |     163.7 ±0% |     174.3 ±1% |            – |            – |     63.8 ±0% |  0.00 ±0% |      1.61 ±9% |   4096000 ±0% |
| scroll | lan     | 202.4 ±4% |      4.87 ±2% |      5.31 ±3% |            – |            – |    40689 ±0% |  65.9 ±4% |      0.60 ±8% |   4096000 ±0% |
| scroll | wan150  |  5.67 ±1% |     175.5 ±0% |     184.1 ±2% |            – |            – |    40689 ±0% |  1.85 ±1% |      2.54 ±9% |   4096000 ±0% |
| photo  | lan     |  15.2 ±0% |      65.7 ±0% |      66.4 ±0% |            – |            – |  3038227 ±0% | 369.3 ±0% |      8.30 ±0% |   4096000 ±0% |
| photo  | wan150  |  1.33 ±0% |     753.8 ±0% |     774.0 ±1% |            – |            – |  3038227 ±0% |  32.4 ±0% |      27.9 ±3% |   4096000 ±0% |
| input  | lan     |         – |             – |             – |     3.39 ±2% |     3.51 ±1% |            – |         – |             – |             – |
| input  | wan150  |         – |             – |             – |    164.9 ±0% |    173.1 ±1% |            – |         – |             – |             – |

## Against /Users/alexandru/codevisor/c1c03091-66c4-4d69-808e-48293c61de1e/currant/docs/measurements/vnc/baseline-Mac16_6.json (build `d070e5249584+dirty`)

| case          | metric        | baseline | current | change | verdict     |
| ------------- | ------------- | -------: | ------: | -----: | ----------- |
| input/lan     | input p50 ms  |     3.50 |    3.39 |    -3% | withinNoise |
| input/lan     | input p95 ms  |     3.53 |    3.51 |    -1% | withinNoise |
| input/wan150  | input p50 ms  |    158.9 |   164.9 |    +4% | withinNoise |
| input/wan150  | input p95 ms  |    166.1 |   173.1 |    +4% | withinNoise |
| photo/lan     | updates/s     |     15.4 |    15.2 |    -1% | withinNoise |
| photo/lan     | update p50 ms |     64.7 |    65.7 |    +2% | withinNoise |
| photo/lan     | update p95 ms |     65.8 |    66.4 |    +1% | withinNoise |
| photo/lan     | bytes/update  |  3038227 | 3038227 |    +0% | withinNoise |
| photo/lan     | CPU ms/update |     8.05 |    8.30 |    +3% | withinNoise |
| photo/lan     | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| photo/wan150  | updates/s     |     1.32 |    1.33 |    +1% | withinNoise |
| photo/wan150  | update p50 ms |    759.3 |   753.8 |    -1% | withinNoise |
| photo/wan150  | update p95 ms |    770.9 |   774.0 |    +0% | withinNoise |
| photo/wan150  | bytes/update  |  3038227 | 3038227 |    +0% | withinNoise |
| photo/wan150  | CPU ms/update |     30.2 |    27.9 |    -7% | withinNoise |
| photo/wan150  | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/lan    | updates/s     |    180.4 |   202.4 |   +12% | improved    |
| scroll/lan    | update p50 ms |     5.25 |    4.87 |    -7% | withinNoise |
| scroll/lan    | update p95 ms |     6.44 |    5.31 |   -18% | improved    |
| scroll/lan    | bytes/update  |    40689 |   40689 |    +0% | withinNoise |
| scroll/lan    | CPU ms/update |     0.75 |    0.60 |   -20% | withinNoise |
| scroll/lan    | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/wan150 | updates/s     |     5.81 |    5.67 |    -2% | withinNoise |
| scroll/wan150 | update p50 ms |    170.7 |   175.5 |    +3% | withinNoise |
| scroll/wan150 | update p95 ms |    179.9 |   184.1 |    +2% | withinNoise |
| scroll/wan150 | bytes/update  |    40689 |   40689 |    +0% | withinNoise |
| scroll/wan150 | CPU ms/update |     2.86 |    2.54 |   -11% | withinNoise |
| scroll/wan150 | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| typing/lan    | updates/s     |    288.7 |   295.8 |    +2% | withinNoise |
| typing/lan    | update p50 ms |     3.34 |    3.32 |    -1% | withinNoise |
| typing/lan    | update p95 ms |     3.40 |    3.38 |    -1% | withinNoise |
| typing/lan    | bytes/update  |     63.8 |    63.8 |    +0% | withinNoise |
| typing/lan    | CPU ms/update |     0.40 |    0.35 |   -13% | withinNoise |
| typing/lan    | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| typing/wan150 | updates/s     |     6.33 |    6.08 |    -4% | withinNoise |
| typing/wan150 | update p50 ms |    156.4 |   163.7 |    +5% | withinNoise |
| typing/wan150 | update p95 ms |    164.5 |   174.3 |    +6% | withinNoise |
| typing/wan150 | bytes/update  |     63.8 |    63.8 |    +0% | withinNoise |
| typing/wan150 | CPU ms/update |     1.73 |    1.61 |    -7% | withinNoise |
| typing/wan150 | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
