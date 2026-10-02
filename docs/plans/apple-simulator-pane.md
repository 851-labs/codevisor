# Apple Simulator pane

A native pane (`PaneKind.simulator`) that shows an Apple simulator running on the workspace's Mac
— in Xcode's own device chrome, with working hardware buttons, rotation, and (for foldables)
posture — on macOS and iOS clients. It replaces the `codevisor-ios-simulator` plugin.

## Pieces

| Where                                                   | What                                                                                                                                                                                                                                                                               |
| ------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `apps/server/src/simulators.ts`, `routes/simulators.ts` | `/v1/simulators/*`: device list, device types (displays, masks, features), DeviceKit chrome bundles, boot/shutdown/restart/delete, create/rename, settings, and screenshots.                                                                                                       |
| `/v1/info`                                              | `simulator-v1` only when Xcode's `simctl` lists runtimes **and** the native app is running to stream (`macNativeHostAvailable`). Linux, a Mac without Xcode, or a server without the app never offer the pane.                                                                     |
| `routes/screen-sharing.ts`                              | Accepts `simulator:<udid>` targets from `simulator` panes.                                                                                                                                                                                                                         |
| `CodevisorCoreMac/Simulator/`                           | The host: `SimulatorRuntime` (CoreSimulator/SimulatorKit via `dlopen` + ObjC runtime), `SimulatorScreenCapture` (framebuffer IOSurface → turned/scaled BGRA), `SimulatorDeviceControl` (input, rotation, posture), `SimulatorStreamHost` (WebRTC senders, one capture per device). |
| `ScreenSharing`                                         | `ScreenSharingSimulatorMessage` on the `codevisor.simulator.v1` data channel (id 14), and the `SimulatorConnection` protocol.                                                                                                                                                      |
| `SimulatorPane` (package)                               | Shared SwiftUI and the viewer: model, `SimulatorStreamConnection` (WebRTC receiver), chrome layout/rendering, Metal screen surface, controls, device picker, settings, Manage Simulators.                                                                                          |

## Video and input

The host registers for a screen's frame callbacks, copies the framebuffer, turns it to fit the device
as it's made (the screen's `nativeRotation`; the Duo's inner screen is mounted sideways), scales it
within the encoder's 3840×2160, and feeds every viewer's WebRTC sender. Viewers draw that screen
inside the device's frame and turn both together as the device is held, so rotation animates like
a real device and iOS rotates its own interface inside the glass. Touches are taken over the screen
as the viewer sees it, in upright normalized coordinates, and the host maps them back to the
framebuffer.

Input goes through CoreDevice feature services inside the guest, reached with
`SimDevice lookup:` → `xpc_endpoint_create_mach_port_4sim` → `xpc_connection_create_from_endpoint`
→ `xpc_connection_enable_sim2host_4sim`. Connections stay open (the guest drops queued events when
the host side disconnects). Messages are `{messageType, isBarrier, featureIdentifier, payload}`:

- `com.apple.coredevice.feature.remote.hid.digitizer`: `IndigoDigitizerEvent` (`pointOne`,
  `pointTwo`, `eventType` 0/1/2, `edge` 1 top 2 left 3 bottom 4 right, `target`),
  `IndigoButtonEvent` (`usagePage`, `usageCode`, `state` 1/2), `IndigoKeyboardButtonEvent`.
- `com.apple.coredevice.feature.remote.hid.vendordefined`: `IndigoVendorDefinedEvent`
  (`usagePage` 0xFF61, `usage` 0x5B, `version` 0 — all uint64 — and `data`, an XML plist the guest's
  locationd relays to CoreMotion). Device Hub's rotation is
  `{source: "orientation-picker-control", type: "enum", value: "portrait"|"pud"|"landscape-left"|"landscape-right"}`;
  a foldable's hinge is `{source: "hinge-slider-control", type: "range", value: <integer degrees>}`
  (closed 0, book ≈130, open 180; ramped so SpringBoard swaps screens as it passes thresholds).
- `com.apple.coredevice.feature.remote.devicecontrol.orientation`: `OrientationRequest`
  `{changeOrientation: {_0: "landscapeLeft"}}`.

SimulatorKit's legacy HID client and a GSEvent to `PurpleWorkspacePort` remain as fallbacks for
runtimes without those services.

## Controls and settings

The pane's controls are native toolbar items (`SimulatorPaneToolbar`), as the Browser, Screen
Sharing, File and Review panes do: the device button leads, Home/Screenshot and Rotate (and a
foldable's posture) sit in the middle of the Mac's window toolbar or along an iPhone's bottom bar,
and Device Settings and More trail. Shortcuts follow Simulator: ⇧⌘H Home, ⌘S Screenshot, ⌘←/⌘→
rotate.

Settings match Device Hub's panel. Appearance, text size and increase contrast go through
`simctl ui`; location through `simctl location`. Reduce Motion, Show Borders, Reduce Transparency,
VoiceOver, volume and the audio output/input routes go through `xcrun devicectl device settings
appearance|voiceover|audio` and read back with `devicectl device info …` (`list audioDevices` names
the Mac's devices). Those reach CoreDevice helpers CoreSimulator runs in every simulator
(`dtconfigurationd`, `com.apple.coredevice.feature.customizeappearancesettings`, `…voiceover`) and,
for audio, CoreSimulator's host audio route. An Xcode without these `devicectl` commands leaves the
settings out of the panel.

## iOS clients

iOS streams the same way the Mac does: `SimulatorStreamConnection` lives in `SimulatorPane`, so both
apps negotiate WebRTC through `/v1/screen-sharing` (with the cloud tunnel for machines elsewhere)
and send input on the simulator channel. There is no snapshot fallback.

WebRTC's iOS slices didn't link with Xcode 27 ("mis-aligned LINKEDIT string pool"): Chromium's
toolchain strips with `llvm-strip`, which leaves the string table 4-byte aligned whenever the
symbol count comes out odd, and Xcode 27's linker refuses that. `scripts/build-webrtc.mjs` now
builds unstripped (`enable_stripping=false`, after dsymutil) and strips each slice with Apple's
`strip -x -S`, then fails the build if any architecture's string table isn't 8-byte aligned.
That build is published as `851-labs/webrtc` `152.0.0-codevisor.2` and pinned everywhere.

The viewer offers only codecs it can decode: HEVC needs VideoToolbox's hardware decoder (every
iPhone and Apple silicon Mac has one), so the iOS Simulator, which has none, negotiates H.264. The
decoder requires hardware everywhere except the Simulator, where it decodes in software.
