# 851-2364 — the viewer doesn't drop frames; macOS sends few

Host: tuftlord (macOS Screen Sharing, 3024×1964), frame-clock video workload,
rig alone, release build. A temporary per-update trace in the viewer (not
merged) logged every update's rectangles and the frame mailbox's replacement
count while the frame clock read the rig's window over the same 30 s.

|                                                                    |        per second |
| ------------------------------------------------------------------ | ----------------: |
| strip updates macOS sent the rig (rectangles above the video area) |              1.33 |
| distinct frames the rig showed (frame clock)                       |              1.23 |
| frames replaced in the mailbox before drawing                      |      6 of 75 (8%) |
| all updates received (strip + video + small)                       | ~2.5, ~120 Mbit/s |

**The presentation path keeps up.** Almost every update is drawn; the few
replaced ones arrived within one display refresh of the next. The rig shows
what macOS sends. On full-screen motion macOS sends a new lossless picture
(~12 MB ZRLE of the moving area) about every 0.7 s, and the strip's changes
ride along at the same pace.

Earlier readings of "the rig drops half" were measurement errors, both fixed:

- The strip count included the video rectangle, which starts just below it.
- The frame-clock reader misread captures whose colour conversion shifted
  (green captured as (154, 247, 95)); thresholds are now on ≥ 180 / off ≤ 170,
  with a test for it.

Also ruled out: the adaptive quality policy (turned off: 1.29 vs 1.13
updates/s, within noise; macOS never sends JPEG anyway).

## Conclusion

Nothing to fix in the viewer for this workload. The remaining gap to Apple's
viewer (~22 updates/s, well under 1 MB per update) is the stream macOS gives
a third-party client. That points to the native path for Mac hosts (851-2365).
