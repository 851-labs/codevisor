# 851-2315: optional Retina (2×) remote desktop — notes

`validate.md` is the gate's output: PASS (tests 318 + 92, interop 10/10,
bench A/B with no verdicts, tophat 24/24). Contabo tophat
(`bun run vnc:tophat --machines contabo`): 12/12, including the new Retina
steps. MachineController, endpoint and surface tests pass
(`swift test --filter 'ScreenSharingViewerEndpointTests|MachineControllerTests|…'`),
and `bun run build:macos` succeeds.

## Decision

alexandru, 2026-09-23: the setting is per machine, saved with the machine,
off by default.

## What changed

- `CodevisorMachine.retinaDesktop` (optional; absent in older records means
  off) and `MachineController.setRetinaDesktop`. Settings → Machines → a
  machine's menu → **Retina Remote Desktop** (a checkmark toggle). Panes
  opened afterwards use it. Cloud machines aren't in the registry, so they
  don't offer it yet.
- `ScreenSharingPane` passes it to `.native(…, retinaDesktop:)`, which reaches
  the VNC runner and the endpoint. The rig has View → Retina Remote Desktop
  per machine (rig defaults), and toggling it reconnects.
- The surface reports its size in points together with its backing scale,
  again when the window changes display. With Retina on, the endpoint asks for
  points × backing scale; with it off, a pixel per point
  (`ScreenSharingViewerEndpoint.desktopSize`, tested for both, including a
  move to a 1× display).
- `vnc:tophat`:
  - `--machines contabo` turns Retina on, checks that the desktop doubles
    (960 × 679 → 1920 × 1358) and shows a picture, then turns it off and waits
    for the original size;
  - the picture check now requires colours and < 30% black (a half-repainted
    desktop fails);
  - window captures pick the largest window, not a popover.

## Acceptance criteria

- Per-machine setting, off by default: done (persisted, tested).
- Framebuffer = surface points × backing scale: done; see the tophat
  screenshots `contabo-1x.png` and `contabo-retina.png`. Text is drawn a pixel
  per device pixel, as sharp as native.
- "Xfce scaling set to 2 by provisioning": **not done**. Setting
  `xsettings /Gdk/WindowScalingFactor` to 2 live (with `xfsettingsd` running,
  and the panel and desktop restarted over the session's D-Bus) didn't reach
  newly opened GTK apps on Contabo, so a 2× desktop draws its UI small but
  sharp. Rather than ship a provisioning option that doesn't work, it is left
  to a follow-up. Contabo was put back to its 1× state (scale 1, theme
  Default, 960 × 679).

## Metric target

"At 2×, typing and scroll meet the 1× update-rate targets; bytes/s
reported." `vnc-bench --runs 3`, same session:

| scene  | profile | 1280 × 800 updates/s | 2560 × 1600 updates/s | 1× Mbit/s | 2× Mbit/s |
| ------ | ------- | -------------------: | --------------------: | --------: | --------: |
| typing | lan     |                 62.2 |                  63.6 |      0.02 |      0.02 |
| typing | wan150  |                 51.2 |                  54.0 |      0.02 |      0.02 |
| scroll | lan     |                 61.5 |                  63.6 |      20.0 |      41.7 |
| scroll | wan150  |                 52.2 |                  54.6 |      17.0 |      35.9 |

Met: update rates hold at 2×; scroll bandwidth doubles.

## Contabo during the checks

A manual `xrandr --fb` during the investigation left Xvnc's output
disconnected until the next client resize restored it. Xfce showed its
"Display" dialog, which I closed. It's noted here because it explains the
half-black frames in the intermediate captures, which weren't a client fault.
