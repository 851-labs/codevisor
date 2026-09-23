# 851-2327: scripted rig tophat — validation

Machine: Apple M4 Max, macOS 27.2, AC power. Base: `f8ef4ff5`.

| Check                           | Result                                                                                                                                                                                                                                       |
| ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| L1 (scripts)                    | `scripts/vnc-tophat-lib.test.mjs`: 4 tests (arguments, verdict, window parsing, clipboard token)                                                                                                                                             |
| `vnc:tophat` (loopback)         | PASS — 24/24 steps                                                                                                                                                                                                                           |
| `vnc:tophat --machines contabo` | PASS — 7/7 steps (Connection Details: VNC · WebSocket)                                                                                                                                                                                       |
| First run                       | 22/23: the clipboard check failed because the flow left the machine before the transfer finished (leaving a machine closes its connection, as hiding a pane does); the flow now waits for the product's "Text sent to the host" confirmation |
| Full suite                      | Pre-commit hook                                                                                                                                                                                                                              |

## The loopback flow

Launch in the background (`open -g`, no focus taken) → Loopback VNC server:
Content "Scene: scroll", "Echo pointer input", Start, "Serving on" → View →
the "Loopback server" machine is selected → two window captures 0.7 s apart
differ (the scene streams through the product viewer) → View and Control
pressed → Connection Details shows "VNC · TCP" → clipboard: a unique token
sent with the toolbar's "Send Clipboard to Machine", confirmed by the
product, found in the reference server's input log (the user's clipboard is
restored) → window resized 1180×760 → 960×640 and still streaming → Stop →
Quit from the menu bar. Screenshots are window-only (`screencapture -l`).

## Acceptance criteria

- **Reusable script:** `bun run vnc:tophat [--machines loopback,contabo]
[--no-build]`, with `scripts/vnc-tophat/rig-ax.swift` (compiled and cached
  per source hash) for Accessibility actions.
- **Background, window-only:** the rig is launched with `open -g`; every
  action is an AX press, selection or resize; captures use the rig's window
  number only.
- **Flows:** View/Control, clipboard to the machine, resize (above). Typing
  needs keyboard focus, which the script never takes; it stays a manual step,
  documented in `docs/plans/vnc-validation.md`. "Clipboard from the machine"
  needs a server-side trigger (the reference server's `sendCutText`); it
  comes with the UTF-8 clipboard issue (851-2316).
- **Summary:** `tmp/vnc-tophat/<time>/summary.json` with every step; exit 0
  only if all passed.

## Rig change

The Loopback VNC server tab's toggles have Accessibility labels ("Animate",
"Echo pointer input") so the script can press them by name.

## Metric target

None (scaffolding).
