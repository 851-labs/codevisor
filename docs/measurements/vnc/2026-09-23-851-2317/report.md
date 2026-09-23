# 851-2317: ⌘ sends Control — notes

`validate.md` is the gate's output: PASS (tests 317 + 92, interop 10/10,
bench A/B with no verdicts, tophat 24/24).

## Decision

alexandru, 2026-09-23: ⌘ → Control (not a per-machine option). Control stays
Control; Super is no longer sent.

## What changed

- `VNCKeyTranslator`: both ⌘ keys (55, 54) send Control_R. The right keysym
  keeps them clear of the left Control key, so holding ⌃ and ⌘ together and
  releasing one never releases the other on the server (Mac laptops have no
  right Control key). The shortcut's letter was already sent unmodified.
- Control–Option–Escape is handled by the surface before translation,
  unchanged (`injectedHostKeysAreNotCapturedAndEscapeReleasesSystemCapture`).

## Acceptance criteria

- L1: the translation table (`modifierKeysHaveTheirOwnKeysyms`, the input
  translator's ⌘ case) expects Control_R.
- L3: `RFBInteropTests.commandActsAsControl` types "discarded", ⌘U, then
  "kept <nonce>" into the container's xterm sink. ⌘U as Control+U kills the
  line, so only "kept <nonce>" arrives. With the old Super mapping the same
  test fails with `typed:discardedukept …` (checked by reverting the table).
- ⌘C/⌘V in an Xfce text editor: to be confirmed on the Contabo desktop with
  851-2322 (the interop container has no Xfce). Terminals copy with
  Control+Shift+C, so ⌘C in a terminal is interrupt and ⌘⇧C copies (noted in
  `docs/plans/vnc-viewer.md`).

## Metric target

Correctness only; bench A/B has no verdicts.
