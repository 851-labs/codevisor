# 851-2319: copy only changed rectangles — notes

`validate.md` is the gate's output: PASS (tests 313 + 92, interop 8/8, bench
A/B against origin/main — typing copied/update −97 % — tophat 24/24). This
run is the new baseline.

## What changed

`VNCFramePublisher.publish(_:changed:to:metrics:)` takes the update's
rectangles. The pixel-buffer pool hands out a buffer only when nothing holds
it (mailbox, renderer), so writing into it never touches a frame on screen;
for each pooled buffer (by IOSurface ID) the publisher keeps the rectangles
changed since that buffer was last written and copies just those,
de-duplicated. A new buffer, a resize, too many pending rectangles, or
pending rectangles adding up to the frame mean one full copy.

## Evidence

- **L2:** every scene's published frame equals the framebuffer after each of
  24 updates while frames are held for varying lengths (buffers come back with
  different backlogs); after warm-up a typing update copies at most 8 glyphs'
  worth, far under 1/1000 of a 1280 × 800 frame; full-frame updates copy the
  frame once; a resize or unknown change copies it whole.
- **Found by the first A/B:** photo and scroll copied 8 MB per update, not 4 —
  a reused buffer's backlog repeated this update's full-frame rectangle.
  Coalescing (duplicates dropped, collapse to one full copy) fixed it, with a
  regression test.

## Metric target

| case            |                   copied/update main → now | CPU ms/update main → now |
| --------------- | -----------------------------------------: | -----------------------: |
| typing / lan    |                4 096 000 → 103 149 (−97 %) |      0.71 → 0.33 (−54 %) |
| typing / wan150 |                4 096 000 → 103 149 (−97 %) |      0.90 → 0.57 (−37 %) |
| scroll, photo   | 4 096 000 → 4 096 000 (full-frame changes) |             within noise |

- "Bytes copied per update ≈ rectangle area": met in steady state (L2: a
  glyph's worth per update; the benchmark's 103 KB average includes one full
  copy when the pool adds a buffer during the 40-update window).
- **"Client CPU per update −80 %" (typing): not met — −54 % / −37 %.** The
  full-frame copy was about 0.4 ms of each typing update; what remains is
  per-update overhead unrelated to copying (decode, the update loop, paced
  scenes' timers and the shaping transport), the same overhead that set the
  0.5 ms CPU noise floor. The target assumed the copy dominated; it was about
  half.
