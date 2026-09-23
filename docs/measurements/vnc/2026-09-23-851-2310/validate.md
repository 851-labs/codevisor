# 851-2310 — vnc:validate

Build `0b8ba6bd518b+dirty` on Mac16,6. Verdict: **PASS**.

| Layer   | Result |  Time | Summary                                                                                                            |
| ------- | ------ | ----: | ------------------------------------------------------------------------------------------------------------------ |
| tests   | pass   |  18 s | packages/swift (RFB\|VNC\|ScreenSharingDiagnostics\|ScreenSharingViewerEndpoint): 260 tests; rig package: 92 tests |
| interop | pass   |  10 s | vnc:interop: PASS — 4 test(s) ran, 0 skipped                                                                       |
| bench   | pass   | 328 s | vnc-bench: no regression beyond the noise band                                                                     |
| tophat  | pass   |  25 s | vnc:tophat: PASS — 24/24 steps.                                                                                    |

## bench

Machine: Mac16,6, macOS 27.2, AC, load 2.6. Build: `0b8ba6bd518b+dirty`.

Median of 3 run(s) per case; ± is the noise band (largest run deviation).

| scene  | profile | updates/s | update p50 ms | update p95 ms | input p50 ms | input p95 ms | bytes/update |    Mbit/s | CPU ms/update | copied/update |
| ------ | ------- | --------: | ------------: | ------------: | -----------: | -----------: | -----------: | --------: | ------------: | ------------: |
| typing | lan     |  62.0 ±1% |      15.8 ±3% |      22.0 ±8% |            – |            – |     63.8 ±0% |  0.03 ±1% |     0.85 ±13% |   4096000 ±0% |
| typing | wan150  |  6.14 ±1% |     163.8 ±1% |     170.5 ±1% |            – |            – |     63.6 ±0% |  0.00 ±1% |     1.62 ±42% |   4096000 ±0% |
| scroll | lan     |  60.7 ±1% |      16.2 ±3% |      21.9 ±7% |            – |            – |    40689 ±0% |  19.8 ±1% |      1.34 ±9% |   4096000 ±0% |
| scroll | wan150  |  5.78 ±2% |     172.6 ±2% |     180.3 ±1% |            – |            – |    40732 ±0% |  1.88 ±2% |     2.05 ±35% |   4096000 ±0% |
| photo  | lan     |  15.7 ±1% |      63.4 ±1% |      64.5 ±3% |            – |            – |  3038227 ±0% | 382.5 ±1% |      8.12 ±1% |   4096000 ±0% |
| photo  | wan150  |  1.34 ±0% |     746.1 ±0% |     765.4 ±0% |            – |            – |  3038226 ±0% |  32.6 ±0% |      27.4 ±7% |   4096000 ±0% |
| input  | lan     |         – |             – |             – |     3.45 ±0% |     3.53 ±0% |            – |         – |             – |             – |
| input  | wan150  |         – |             – |             – |    165.0 ±1% |    169.8 ±1% |            – |         – |             – |             – |

## Against /Users/alexandru/codevisor/c1c03091-66c4-4d69-808e-48293c61de1e/currant/docs/measurements/vnc/baseline-Mac16_6.json (build `0b8ba6bd518b+dirty`)

| case          | metric        | baseline | current | change | verdict     |
| ------------- | ------------- | -------: | ------: | -----: | ----------- |
| input/lan     | input p50 ms  |     3.42 |    3.45 |    +1% | withinNoise |
| input/lan     | input p95 ms  |     3.54 |    3.53 |    -0% | withinNoise |
| input/wan150  | input p50 ms  |    163.7 |   165.0 |    +1% | withinNoise |
| input/wan150  | input p95 ms  |    170.1 |   169.8 |    -0% | withinNoise |
| photo/lan     | updates/s     |     15.5 |    15.7 |    +1% | withinNoise |
| photo/lan     | update p50 ms |     64.3 |    63.4 |    -2% | withinNoise |
| photo/lan     | update p95 ms |     65.0 |    64.5 |    -1% | withinNoise |
| photo/lan     | bytes/update  |  3038227 | 3038227 |    +0% | withinNoise |
| photo/lan     | CPU ms/update |     8.25 |    8.12 |    -2% | withinNoise |
| photo/lan     | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| photo/wan150  | updates/s     |     1.34 |    1.34 |    +0% | withinNoise |
| photo/wan150  | update p50 ms |    748.6 |   746.1 |    -0% | withinNoise |
| photo/wan150  | update p95 ms |    766.8 |   765.4 |    -0% | withinNoise |
| photo/wan150  | bytes/update  |  3038226 | 3038226 |    +0% | withinNoise |
| photo/wan150  | CPU ms/update |     27.6 |    27.4 |    -1% | withinNoise |
| photo/wan150  | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/lan    | updates/s     |     61.4 |    60.7 |    -1% | withinNoise |
| scroll/lan    | update p50 ms |     16.2 |    16.2 |    +0% | withinNoise |
| scroll/lan    | update p95 ms |     20.6 |    21.9 |    +6% | withinNoise |
| scroll/lan    | bytes/update  |    40689 |   40689 |    +0% | withinNoise |
| scroll/lan    | CPU ms/update |     1.36 |    1.34 |    -1% | withinNoise |
| scroll/lan    | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| scroll/wan150 | updates/s     |     5.79 |    5.78 |    -0% | withinNoise |
| scroll/wan150 | update p50 ms |    171.9 |   172.6 |    +0% | withinNoise |
| scroll/wan150 | update p95 ms |    183.4 |   180.3 |    -2% | withinNoise |
| scroll/wan150 | bytes/update  |    40732 |   40732 |    +0% | withinNoise |
| scroll/wan150 | CPU ms/update |     2.53 |    2.05 |   -19% | withinNoise |
| scroll/wan150 | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| typing/lan    | updates/s     |     61.2 |    62.0 |    +1% | withinNoise |
| typing/lan    | update p50 ms |     16.2 |    15.8 |    -2% | withinNoise |
| typing/lan    | update p95 ms |     23.2 |    22.0 |    -5% | withinNoise |
| typing/lan    | bytes/update  |     63.8 |    63.8 |    +0% | withinNoise |
| typing/lan    | CPU ms/update |     0.47 |    0.85 |   +82% | withinNoise |
| typing/lan    | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
| typing/wan150 | updates/s     |     6.16 |    6.14 |    -0% | withinNoise |
| typing/wan150 | update p50 ms |    162.0 |   163.8 |    +1% | withinNoise |
| typing/wan150 | update p95 ms |    170.7 |   170.5 |    -0% | withinNoise |
| typing/wan150 | bytes/update  |     63.6 |    63.6 |    +0% | withinNoise |
| typing/wan150 | CPU ms/update |     1.54 |    1.62 |    +5% | withinNoise |
| typing/wan150 | copied/update |  4096000 | 4096000 |    +0% | withinNoise |
