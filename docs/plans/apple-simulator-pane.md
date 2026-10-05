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

The host registers for a screen's frame callbacks, copies the framebuffer as it is, scales it
within the encoder's 3840×2160, and feeds every viewer's WebRTC sender. Viewers draw that screen
inside the device's frame and turn both together: by how the screen is mounted in the device
(`screenTurns` in the state) plus how the device is held, so rotation animates like a real device
and iOS rotates its own interface inside the glass. A screen's mounting is its capabilities'
`nativeRotation` plus the device's `main-screen-orientation` (radians): an iPad's 270° and 90° (a
Watch's 90° and 270°) cancel, so only the iPhone Duo's inner screen is sideways, and it opens in
landscape, as in Device Hub. Touches are taken over the screen as the viewer sees it, in upright
normalized coordinates, and the host maps them back to the framebuffer.

A foldable is drawn at one size whichever screen shows (the state's `mountings` give every
screen's mounting, so the viewer lays out both). On the inner screen the device is two live copies
(`SimulatorScreenFeed` tees the receiver's frames into a mailbox per copy, renewed whenever the
arrangement changes, since a stopping video view clears its mailbox's callback), each clipped to
one side of the hinge and projected about it (`SimulatorFold`): flat when open, both halves
tilted toward you as a book, touches flattened back through the projection. Swapping screens
animates the hinge over stills: the panel swings 180° about the hinge, showing the inner half on
its front and the cover screen on its back, then hands back to the live stream. The guest wakes
the screen it moves to black and fades it up from dim, so the viewer holds the stream's frames
(`SimulatorScreenFeed.awaitWake`) and shows that screen's last still until frames of the new size
are lit and settled (mean luma steady between frames, or nothing newer for a moment; at most
1.2 s), and the fold reads as one pane of glass, as in Device Hub. A screen not seen yet (the
first unfold) stands in with the other screen's still, filled and blurred, as SpringBoard's own
wake looks. Each half is drawn as a slab in perspective (`SimulatorFold.plane`): its body is one
shape behind the face, the convex hull of the device's rounded outline projected at the front and
back of the panel, so the rim that shows as it turns toward you joins the face and rounds its
corners smoothly, as the device does, faces darken as they turn from the light, and the cover sits a
panel's thickness above the half it closes on. The right half reaches a hair under the left, so
the two antialiased edges at the hinge leave no seam, and the open bezel's middle is stretched from
a plain strip of the composite (its center carries a hinge mark). A posture asked for in this pane
pins the screen's frame as the button is pressed (`SimulatorScreenFeed.pin`): by the time the
device answers, the guest has already redrawn the departing screen mid-transition (the next
screen's layout, squashed), which would otherwise become its still. Buttons whose
artwork lies across their edge (the inner chrome reuses the cover's) are turned a quarter to lie
along it. Buttons are placed against the device's visible edge (some composites, like the Duo's
cover, carry a clear margin outside it) and stand at most 3 points proud, as Device Hub draws them;
a composite's corner caps reach as far as its continuous corner curves, so stretching never flattens
a corner. The posture controls are Device Hub's: closed, book and flat glyphs beside Rotate.

Input goes through CoreDevice feature services inside the guest, reached with
`SimDevice lookup:` → `xpc_endpoint_create_mach_port_4sim` → `xpc_connection_create_from_endpoint`
→ `xpc_connection_enable_sim2host_4sim`. Connections stay open (the guest drops queued events when
the host side disconnects). Messages are `{messageType, isBarrier, featureIdentifier, payload}`:

- `com.apple.coredevice.feature.remote.hid.digitizer`: `IndigoDigitizerEvent` (`pointOne`,
  `pointTwo`, `eventType` 0/1/2, `edge` 1 top 2 left 3 bottom 4 right, `target`: 0 the main
  touchscreen, otherwise the screen's `screenID`, 3 for the Duo's inner screen). The guest's
  `dtuhidd` brings its touchscreens up about half a second after a connection, so the host connects
  as it attaches.
  `IndigoButtonEvent` (`usagePage`, `usageCode`, `state` 1/2), `IndigoKeyboardButtonEvent`.
- `com.apple.coredevice.feature.remote.hid.vendordefined`: `IndigoVendorDefinedEvent`
  (`usagePage` 0xFF61, `usage` 0x5B, `version` 0 — all uint64 — and `data`, a dictionary the guest's
  locationd relays to CoreMotion). locationd reads it with `IOCFUnserialize`, so `data` is IOKit's
  serialization (plist tags without the XML declaration or DOCTYPE, integers not reals), and its
  relay refuses anything past a few hundred bytes, which a full XML plist of one value already is. Device Hub's rotation is
  `{source: "orientation-picker-control", type: "enum", value: "portrait"|"pud"|"landscape-left"|"landscape-right"}`;
  a foldable's hinge is `{source: "hinge-slider-control", type: "range", value: <integer degrees>}`
  (closed 0, book ≈130, open 180; ramped so SpringBoard swaps screens as it passes thresholds).
  The guest can't be asked its hinge angle, so the host folds a foldable closed as it attaches, to
  match the posture it reports.
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
`simctl ui`; location through `simctl location`. Liquid Glass (`--liquid-glass-opacity`, 0 clear to
1 tinted), Color Filter (`--color-filter on|off` with `--color-filter-type` protanopia, deuteranopia,
tritanopia or grayscale; read back as `colorFilter.filterType.name`), Reduce Motion, Show Borders,
Reduce Transparency, VoiceOver, volume and the audio output/input routes go through `xcrun devicectl
device settings appearance|voiceover|audio` and read back with `devicectl device info …` (`list
audioDevices` names the Mac's devices). A runtime without Liquid Glass reports no opacity, so the
slider is left out. Those reach CoreDevice helpers CoreSimulator runs in every simulator
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
That build was published as `851-labs/webrtc` `152.0.0-codevisor.2`.

The pane is also the first thing to put WebRTC in the iOS app, and build 2 crashed it at launch
on a device ("Library not loaded: @rpath/libswiftCoreMedia.dylib"). The recipe built the iOS
slices for iOS 12, older than Swift in the OS, so they loaded Swift's libraries through `@rpath`,
which a device doesn't resolve to `/usr/lib/swift`; the Simulator's dyld finds them anyway. The
recipe now leaves `ios_deployment_target` at WebRTC's own default (iOS 14 at M152), where the
slices link the system CoreMedia directly. That is build 3, `152.0.0-codevisor.3`, pinned
everywhere; its macOS slice is unchanged.

The viewer offers only codecs it can decode: HEVC needs VideoToolbox's hardware decoder (every
iPhone and Apple silicon Mac has one), so the iOS Simulator, which has none, negotiates H.264. The
decoder requires hardware everywhere except the Simulator, where it decodes in software.
