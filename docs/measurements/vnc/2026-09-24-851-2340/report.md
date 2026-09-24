# 851-2340: Dynamic Resolution toolbar toggle — notes

`validate.md` is the gate's output: PASS (tests 329 + 102, interop 10/10,
bench A/B with no verdicts, tophat 24/24). The Contabo tophat
(`--machines contabo`) passed 13/13, and `bun run build:macos` succeeds. Suites:
`ScreenSharingDynamicResolutionTests` 3, `ScreenSharingViewerEndpointTests`
9, `ScreenSharingViewerTests` 10, `ScreenSharingMachinePreferencesTests` 1,
`MachineControllerTests` 20, the VNC and native backend suites 4 + 11.

## Decisions (alexandru, 2026-09-23)

A toolbar toggle, per machine, default on. Off restores the default size and
1×. It replaces 851-2315's Retina setting.

## What changed

- **Toggle:** `ScreenSharingDynamicResolutionToggle`, next to View/Control in
  the app's and the rig's toolbars, shown only for sessions that resize their
  desktop (`resizesDesktop`: VNC, not the Mac backend).
- **Preference:** `ScreenSharingMachinePreferences`, keyed by machine id, so
  Codevisor Cloud machines work too; default on. The rig keeps its own
  `RigMachineSettings`. Removed: `CodevisorMachine.retinaDesktop`,
  `MachineController.setRetinaDesktop`, the Settings → Machines item and the
  rig's View menu item.
- **Endpoint:**
  - on: the desktop follows the pane. The scale comes from
    `ScreenSharingDynamicResolution` (the backing scale; 1× below ~15 Mbit/s,
    back to 2× above ~25).
  - 2× pixels only when the desktop can draw at 2× (the display lists scale 2,
    851-2339), and then `setScale` goes to the machine's server when the scale
    changes.
  - off: nothing is sent. If this viewer had changed the desktop, it restores
    the provisioned size (or the size at connect) and 1×.
  - Connection Details shows "dynamic · 2×" / "dynamic · 1× (slow link)" /
    "fixed size".
- **Reducer:** `dynamicResolution` and `dynamicResolutionToggled`, applied to
  each new endpoint with the display's default size and scales, through
  `ScreenSharingEndpointClient`.

## A catch fixed before it shipped

Contabo runs server 0.1.102, which has no `setScale`. With the toggle on by
default, a Retina pane would have asked for a 2× desktop while Xfce stayed at
1×, so everything would have shown at half size. The pane now uses 2× pixels
only when the server says the desktop can draw at 2×.

## Contabo (tophat, server 0.1.102)

- off: resizing the rig window left the desktop at 960 × 679;
- on: it followed the smaller window (760 × 559) and back (960 × 679);
- 1× pixels throughout, since this server lists no scales.

The 2× path, with the server setting Xfce's scale, will be checked once
Contabo runs a server with 851-2339.
