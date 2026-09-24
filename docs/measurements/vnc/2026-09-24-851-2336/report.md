# 851-2336: vnc-bench --pace 0 hangs with continuous updates — notes

`validate.md` is the gate's output: PASS (tests 325 + 102, interop 10/10,
bench A/B with no verdicts, tophat 24/24).

## Cause

`--pace 0` plays a scene frame per incremental FramebufferUpdateRequest. The
bench's `vnc-server` also offered continuous updates, so since 851-2312 the
client switched to pushed updates and stopped requesting. No request meant no
frame, and the run hung until the 180 s watchdog.

## Fix

- `VNCBenchServer.arguments` (RigKit, tested): `--pace 0` passes
  `--requested-only`, so the server offers no continuous updates and the
  client keeps requesting.
- `vnc-server` implies `--requested-only` for any scene played on request
  (no `--scene-fps`), as a second safety.
- The watchdog's message names the likely cause when a run stalls.

## Evidence

`vnc-bench --scenes photo,typing --profiles lan --runs 1 --pace 0` now
finishes: photo 15.4 updates/s, typing 299.7 updates/s (the request-driven
maximum). Before, it stopped after 180 s with no update.
