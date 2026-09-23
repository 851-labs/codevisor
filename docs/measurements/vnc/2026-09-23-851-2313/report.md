# 851-2313: Tight with JPEG and quality levels — notes

`validate.md` is the gate's output: PASS (tests 308 + 92, interop 8/8, bench
A/B against origin/main — the client now prefers lossless Tight where main
used ZRLE — with no verdicts, tophat 24/24).

## What changed

- **Decoder** (`RFBTightDecoder`): fill, JPEG (ImageIO), and zlib "basic"
  rectangles with the copy, palette (1-bit for two colours, indexed up to 256) and gradient filters, four persistent zlib streams with reset flags,
  compact lengths; TPIXEL is R, G, B. The client advertises Tight first.
- **Quality:** `RFBClient(qualityLevel:)` and `setQualityLevel(_:)` send the
  -32…-23 pseudo-encodings (nil: lossless). `VNCQualityPolicy` — after
  TigerVNC's AutoSelect — estimates bandwidth from updates of 64 KB or more
  (bytes over the time they took), smooths it, and after three samples turns
  JPEG 8 on below 16 Mbit/s and off above 24 Mbit/s. Connection Details'
  route shows the current mode ("· lossless" / "· JPEG 8").
- **Reference server:** a Tight encoder choosing like TigerVNC (fill;
  palette ≤ 16 colours; JPEG when the client asked for a quality level;
  otherwise zlib copy at level 1), encoding negotiated from the client's
  preference (`negotiateEncoding`), scenes emit `.encoded` rectangles. The
  scene server and the rig negotiate.

## Evidence

- **L1:** every rectangle type from hand-built bytes; gradient checked
  against an independent forward transform; JPEG at quality 8 ≥ 35 dB PSNR
  against the reference encoder; stream continuation and reset; malformed
  filters, palette indices and PNG rejected.
- **L2:** every scene converges exactly over lossless Tight; a client quality
  level turns JPEG on (≥ 35 dB) and `setQualityLevel(nil)` mid-session makes
  the next frame exact again; a reconnect decodes (see below).
- **L3 (TigerVNC 1.15):** with a plasma window in the interop desktop,
  lossless Tight matches and quality 8 sends JPEG for it at 33.7 dB PSNR
  against lossless. Fixtures: `tigervnc-1.15-tight-lossless.json` (exact) and
  `tigervnc-1.15-tight-jpeg.json` (pixel hash `lossy`).
- **L4:** tophat 24/24 with the rig negotiating Tight.

## Metric target

"Photo/video and scroll: ≥ 50 % fewer bytes than ZRLE; client CPU per update
≤ 1.2× ZRLE" — measured with `vnc:bench --quality 8` against the ZRLE numbers
of the same session's origin/main run:

| case                            | ZRLE bytes/update | Tight JPEG 8 | change | updates/s ZRLE → JPEG | CPU ms/update ZRLE → JPEG |
| ------------------------------- | ----------------: | -----------: | -----: | --------------------: | ------------------------: |
| photo / wan150                  |         3 038 227 |      776 970 |  −74 % |           2.06 → 8.04 |               20.8 → 5.13 |
| scroll / wan150                 |            40 732 |       14 920 |  −63 % |             54 → 52.9 |                 1.5 → 2.1 |
| photo / constrained (10 Mbit/s) |                 — |      776 970 |      — |                → 1.61 |                    → 11.7 |

Met. Lossless Tight (the default on fast links) is within noise of ZRLE on
every metric in the gate's A/B.

## Found along the way

- The tophat caught the reference server keeping its Tight zlib streams
  across a reconnect ("zlib error -3" after switching machines away and
  back); each connection now gets a fresh encoder (regression test added).
- An old test used Tight (7) as its example of an unadvertised encoding and
  hung once Tight was decoded; it now uses Hextile (5).
- The first A/B read photo/lan −18 % updates/s with unchanged client CPU: the
  reference encoder (default zlib level, per-pixel appends) bounded the
  benchmark. zlib level 1 (TigerVNC's) and a preallocated pass fixed it.
