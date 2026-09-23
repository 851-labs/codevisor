# 851-2318: synthesized typing sent as text — notes

`validate.md` is the gate's output: PASS (tests 316 + 92, interop 9/9, bench
A/B with no verdicts, tophat 24/24). The surface tests aren't in the gate's
filter; `swift test --filter 'ScreenSharingInputSurfaceTests|VNCKeyTranslator|VNCInputTranslator'`:
27 passed.

## What changed

- `ScreenSharingInputSurface`: a key-code-0 press (what Computer Use
  `typeText` posts) whose characters aren't what that key gives on the local
  layout, without Control or Command, goes out as `.text(characters)`; its
  release is swallowed. Every other key is unchanged (a real A key, ⇧A and ⌃A
  stay physical). The layout is injected, so the tests don't depend on the
  developer's keyboard.
- `.text` already reached a VNC server as the characters' keysyms (Latin-1
  direct, `0x1000000 + code point` beyond) and the native host as a Unicode
  key event, so both backends benefit.
- `VNCKeyTranslator.carbonModifiers` is shared by the translator and the
  surface's check.

## Acceptance criteria

- Synthesized Unicode input sent as keysyms, physical keys unchanged:
  `synthesizedTypingIsSentAsTextAndPhysicalKeysStayKeys`,
  `controlAndCommandKeepKeyCodeZeroPhysical` (both failed before the change:
  key code 0 went out as `.key`).
- L3: `RFBInteropTests.synthesizedTypingArrivesVerbatim`. The interop
  container gained a typing sink (an xterm that puts each typed line on the
  clipboard as `typed:<line>`); "Hello, wörld! <nonce>" typed through
  `VNCInputTranslator` came back verbatim from TigerVNC 1.15.
- QEMU Extended Key Events (−258): considered and deferred. Scancodes hand
  layout interpretation to the server, which is the same product decision as
  what ⌘ sends (851-2317); noted in `docs/plans/vnc-viewer.md`.

## Metric target

Correctness only; bench A/B has no verdicts.
