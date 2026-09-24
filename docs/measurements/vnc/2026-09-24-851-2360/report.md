# 851-2360 — more requests in flight: no gain on a Mac host

Host: tuftlord (macOS Screen Sharing, 3024×1964), frame-clock video workload.
Release builds.

## Depth (outstanding incremental requests), in the real viewer

Frame clock, rig and Apple Screen Sharing side by side, 30 s each:

| rig request depth    | rig updates/s | rig lag behind Apple p50 / p95 | Apple updates/s |
| -------------------- | ------------: | -----------------------------: | --------------: |
| 1 (today)            |          1.65 |                  500 / 1783 ms |            22.8 |
| 2, request on header |          1.18 |                  650 / 2517 ms |            21.6 |

Headless (`vnc-sample --depth`, 20 s) raised updates/s up to 2.5 at depth 4,
but each answer was encoded later, so the viewer got worse, not better.

## Bands (requesting the screen as N horizontal strips)

`vnc-sample --bands N` (experiment, not merged), our client alone:

|            bands |                                                updates/s |
| ---------------: | -------------------------------------------------------: |
| 1 (whole screen) |                                                     4.93 |
|      2, 4, 8, 16 | **0**: macOS answers nothing for partial-screen requests |

## What it shows instead

- With only our client connected, the headless client gets **4.9 updates/s**
  (server wait 25 ms p50, 2.6 MB/update); with Apple's viewer also connected
  it got 1.9/s (server wait 279 ms). A second viewer slows macOS's server.
- The rig alone on the same workload shows **1.13 updates/s** (gap p50
  871 ms): our viewer loses ~4× against its own protocol client. That's
  851-2364.

## Decision

Keep one request in flight. No product change; the `vnc-sample --depth/--early`
tooling (851-2361) stays for measuring.
