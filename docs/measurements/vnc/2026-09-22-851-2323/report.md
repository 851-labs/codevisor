# 851-2323: extensible reference server — validation

Machine: Apple M4 Max, macOS 27.2, AC power. Base: `e57f60ed`.

`bun run vnc:validate` does not exist yet (851-2328), so the available layers
were run directly. This issue builds part of the scaffolding the missing
layers depend on.

| Layer          | Result                                                                                                                                                       |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| L1/L2          | `RFBReferenceServerTests`, `RFBLoopbackServerTests`, `RFBClientLoopbackTests`: 37 tests pass; 10 consecutive runs pass (≈2.0 s each)                         |
| L1/L2 (full)   | Full Swift suite via the pre-commit hook                                                                                                                     |
| L3 (real Xvnc) | Not available until 851-2325; this change adds no client behaviour                                                                                           |
| Benchmark      | Not available until 851-2310; this change adds no client behaviour, so there is nothing to compare                                                           |
| L4 (rig)       | Loopback VNC server → Content "Scene: scroll", pointer echo on → View: the scene streams through the product's viewer; window-only captures 1 s apart differ |

## Acceptance criteria

- **Seam per encoding / extension:** `RFBLoopbackServer.implementedEncodings`
  declares what the server can send; later features add their server side and
  their entry together.
- **Scripted scenes:** `RFBLoopbackScene` (idle, typing, scroll, windowDrag,
  photo, resize), a function of kind, seed and frame count (SplitMix64, stable
  per-kind hash). `aSceneIsAFunctionOfItsSeed` checks the same seed replays
  identical pixels and rectangles and a different seed changes them;
  `theClientConvergesOnEveryScene` plays eight frames of every scene to a real
  client and checks its framebuffer equals the server's after each one
  (colour bytes; the fourth byte is padding in depth 24). `play` refuses a
  frame while the previous one is unsent, because pixels are encoded when sent
  (`aFrameWaitsForThePreviousOneToBeSent`).
- **Input echo:** `Configuration.echoPointer` paints a 4×4 marker whose colour
  encodes the event's sequence (`echoMarker` / `echoSequence`), checked at the
  pointer position by `pointerInputIsEchoedAsAMarkerAtThePointer`; off by
  default (`withoutEchoPointerInputChangesNothing`).
- **Parity test:** `implementsEveryEncodingTheClientAdvertises` fails when
  `RFBEncoding.supported` holds anything the server can't send.
- **Rig:** the Loopback VNC server tab can play any scene (seed 1) and echo
  pointer input.

## Metric target

None (scaffolding). No client code changed.
