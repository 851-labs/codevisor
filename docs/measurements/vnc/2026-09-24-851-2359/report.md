# 851-2359 — where our client's time goes on a Mac host

`screen-sharing-rig vnc-sample --keychain tuftlord-mac --seconds 30 --trace …`,
release build, against tuftlord (macOS Screen Sharing, 3024×1964) showing the
frame-clock page's video workload (851-2358). `vnc-sample` is the product's
`RFBClient` without the UI, so this is the protocol path alone.

## Per stage (30 s, 62 updates)

| stage                                                 |        p50 |    p95 |
| ----------------------------------------------------- | ---------: | -----: |
| request → first byte (round trip + server's own time) | **279 ms** | 808 ms |
| network transfer (reads that waited for the link)     |     1.5 ms | 270 ms |
| decode (apply minus transfer)                         |       5 ms | 171 ms |
| request → update applied                              |     442 ms |      – |

|              |                                        |
| ------------ | -------------------------------------- |
| encoding     | ZRLE only (62 of 62 updates)           |
| updates/s    | 1.94                                   |
| throughput   | 89 Mbit/s                              |
| bytes/update | mean 5.7 MB; median 20 KB, max 12.5 MB |
| area/update  | median 8% of the screen, max 100%      |
| decode       | 26 ms per megapixel                    |

## What it says

- **The server's wait dominates.** Even when an update is small (median 20 KB,
  one rectangle), macOS answers a request after ~450 ms (p50 request → applied,
  7 ms of which is ours). With one request in flight at a time, that caps us at
  ~2 updates/s before the viewer does anything (851-2360).
- **The frames that are big are very big.** Full-screen noise in lossless ZRLE
  is up to 12.5 MB per update (~4:1 over raw 23.7 MB), so the link carries
  ~89 Mbit/s for ~2 updates/s. A lossy encoding (851-2361) or fewer pixels
  (851-2363) would cut that by an order of magnitude.
- **Decode is not the bottleneck at p50** (5 ms), but its p95 (171 ms, big
  frames) sits on the read path and delays the next request (851-2362).
- The rig showed 0.6 updates/s on the same workload (851-2358) against this
  client's 1.9: the viewer path loses another ~3× (presentation, main-actor
  work; 851-2364).

## Tooling added

- `vnc-sample --keychain MACHINE`: signs in with the rig's stored credential
  (Mac account included); nothing printed or written.
- `vnc-sample --trace FILE`: one JSON line per update (time, bytes, rectangles
  per encoding, area, latency, apply, link).
- Summary: `serverWait`, `transfer`, `decode` p50/p95, `decodeMsPerMegapixel`,
  and the encoding histogram.
- `RFBUpdate.encodingCounts`: rectangles per encoding number, pseudo-encodings
  included.
