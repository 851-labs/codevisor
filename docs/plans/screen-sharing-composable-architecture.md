# Screen Sharing composable architecture

Status: Implemented on `screen-sharing-composable-architecture`; the native path was tophatted in the dev app (connect, Fit/Actual Size, hide and re-show reconnect with the persisted preference, Connection Details, Clipboard menu). This refactor keeps the shipped Mac-to-Mac path behavior-identical and cuts the seams a second backend (a standard VNC/RFB viewer) plugs into later. No VNC code lands here. See [the native implementation plan](native-screen-sharing.md) for the shipped feature and [the media package README](../../packages/swift/CodevisorScreenSharing/README.md) for measured results.

**Why**

`CodevisorScreenSharing` is a WebRTC pipeline end to end: ScreenCaptureKit → VideoToolbox → SRTP, three negotiated SCTP channels, one-shot SDP over the Codevisor server. The viewer seam (`ScreenSharingViewingPeer`) is SDP-shaped (`offer()`/`accept(answer)`), the video surface is constructed from a `ScreenSharingPeer`, the Metal renderer accepts only biplanar YCbCr, and the viewer model hand-rolls signaling, heartbeats, recovery and cancellation with a generation counter. A VNC viewer shares nothing on the wire with any of that, so today it could only be added by faking SDP strings and CPU-converting RGB to NV12.

**Two altitudes, not one plugin per layer**

A plugin per layer (`Capture × Codec × Transport × Input`) is right for the native path, where the stages are genuinely separable, and wrong for RFB, where encoding, transport and decoding are fused inside one protocol. The architecture therefore has two altitudes:

1. **Session contracts** — what the feature depends on. A viewing session exposes frames, control, clipboard and diagnostics as optional capabilities. Backends implement this; the feature never learns which one it is talking to.
2. **Pipeline toolkit** — capture sources, codecs, the WebRTC peer, the Metal renderer, input translation. Backends compose from it. The native backend uses all of it; a VNC backend would use the renderer, the input surface and the clipboard transfer, and bring its own protocol module.

One further cut governs where each technique applies. The **control plane** (visibility, display choice, connect/reconnect/stop, lease requests, failure messages) changes a few times a minute and is where a reducer, dependency injection and exhaustive tests pay off. The **data plane** (60 fps frames, ~1 kHz input, 1 Hz lease heartbeats, clipboard chunks) stays as it is: mailboxes, closures and main-actor objects, no actions per frame.

## Target graph

```mermaid
flowchart TB
    Core[ScreenSharingCore<br/>frames, mailbox, metrics, input + control + clipboard messages,<br/>clipboard transfer, message-channel contract, viewing-session contract]
    Media[CodevisorScreenSharing<br/>WebRTC peer, codec factory, encoder/decoder, capture, Metal renderer]
    HostInput[ScreenSharingHostInput]
    CoreMac[CodevisorCoreMac<br/>native viewer backend, video surface, input surface,<br/>ScreenSharingViewer reducer]
    App[macOS app<br/>ScreenSharingPane, ScreenSharingToolbar]
    TCA[(ComposableArchitecture)]
    WebRTC[(WebRTC)]
    Media --> Core
    Media --> WebRTC
    HostInput --> Media
    CoreMac --> Media
    CoreMac --> HostInput
    CoreMac --> TCA
    App --> CoreMac
```

`ScreenSharingCore` links no WebRTC, Metal, ScreenCaptureKit or AppKit. `CodevisorScreenSharing` re-exports it (`@_exported import ScreenSharingCore`), so every existing `import CodevisorScreenSharing` keeps compiling. The rule the graph enforces: a future `ScreenSharingVNC` target depends on `ScreenSharingCore` and never on `CodevisorScreenSharing`; the build fails if it tries.

Files that move into `ScreenSharingCore` (unchanged content, `git mv`): `ScreenSharingVideoConfiguration` (error, configuration, `ScreenSharingVideoFrame`, `ScreenSharingFrameMailbox`), `ScreenSharingControlMessage`, `ScreenSharingClipboardMessage`, `ScreenSharingClipboardTransfer`, `ScreenSharingMetrics` (+Presentation), `ScreenSharingFrameDeliveryAudit`, `ScreenSharingFrameIdentity`, `ScreenSharingScrollAccumulator`. Everything that imports WebRTC, VideoToolbox, MetalKit or ScreenCaptureKit stays.

## Contracts

All contracts live in `ScreenSharingCore`.

```swift
/// An ordered, reliable, bounded message channel. Today: one negotiated SCTP
/// data channel. Later: a TCP side channel, a WebSocket via the server, or an
/// in-memory pair in tests.
@MainActor
public protocol ScreenSharingMessageChannel<Message>: AnyObject {
  associatedtype Message: Sendable
  var isAvailable: Bool { get }
  var onMessage: ((Message) -> Void)? { get set }
  var onAvailabilityChanged: ((Bool) -> Void)? { get set }
  @discardableResult func send(_ message: Message) -> Bool
  func close()
}

/// In-memory pair for tests and for backends that carry control locally.
@MainActor public final class ScreenSharingLocalChannel<Message: Sendable>: ScreenSharingMessageChannel

public struct ScreenSharingCapabilities: OptionSet, Sendable {
  public static let control, clipboard, statistics: Self
}

/// One live media session as the viewer sees it. No SDP, no signaling, no
/// AppKit: the feature builds its own surface from `frames`.
@MainActor
public protocol ScreenSharingViewingSession: AnyObject {
  var capabilities: ScreenSharingCapabilities { get }
  var frames: ScreenSharingFrameMailbox { get }
  var metrics: ScreenSharingMetrics { get }
  var control: (any ScreenSharingMessageChannel<ScreenSharingControlMessage>)? { get }
  var clipboard: (any ScreenSharingMessageChannel<ScreenSharingClipboardMessage>)? { get }
  /// A terminal media failure (today: the hardware decoder), nil while healthy.
  var failure: String? { get }
  /// Transport state names; "failed", "disconnected" and "closed" are acted on.
  var onConnectionChanged: ((String) -> Void)? { get set }
  func statistics() async -> [String: String]
  func close()
}
```

`ScreenSharingDataChannel` conforms to `ScreenSharingMessageChannel`; `ScreenSharingViewerClipboard` and the viewer control take the protocol. The lease/grant protocol stays a _control-message_ concern layered on any channel; it is the native backend's access model, not a universal. A backend without `.control` in its capabilities never shows a Request Control affordance.

**Backend** (in `CodevisorCoreMac`, a TCA dependency):

```swift
public enum ScreenSharingViewerEvent: Equatable, Sendable {
  case opened(ScreenSharingViewerEndpoint)   // new media to render; replaces any previous endpoint
  case ready                                  // first frame presented
  case reconnecting                           // transport loss; a fresh `opened` follows or `ended`
  case controlReleased                        // the host revoked or the surface lost the lease
  case ended(String)                          // terminal, with the message to show
}

public struct ScreenSharingViewerBackend: Sendable {
  public var discover: @Sendable () async throws -> [ServerScreenSharingDisplay]
  public var connect: @MainActor @Sendable (_ displayId: String) -> AsyncStream<ScreenSharingViewerEvent>
}
```

The native `connect` is one main-actor runner per pane: a new discovery or connection awaits the previous connection's teardown, including its authenticated stop, so a stop can never overtake the next start (the ordering the old view model got from awaiting its previous task).

`ScreenSharingViewerBackend.native` owns everything that is Codevisor-server-specific and used to live in the view model: capabilities → offer → `start` → answer → 8 s heartbeats → `stop`, the 3-restart recovery with the same `viewerId`, the "no video after three heartbeats" watchdog and the stop-in-a-fresh-task rule. Cancelling the stream is the only way to end a connection; termination performs the authenticated `stop`.

`ScreenSharingViewerEndpoint` is the main-actor handle the reducer keeps in state: the `NSView` surface, `ScreenSharingViewerControl`, `ScreenSharingViewerClipboard?`, `ScreenSharingViewerDiagnostics`. It is `Equatable` by identity. Those three objects stay `@Observable`; they are data-plane state (1 Hz ticks, input events, chunk transfers) and are observed directly by the pane, not routed through actions.

**Reducer** (`ScreenSharingViewer`, `CodevisorCoreMac`): state is `phase`, `interactionMode`, `message`, `displays`, `selectedDisplayId`, `preferences`, `preferencesRevision`, `endpoint`. Actions are the pane's intents (`setVisible`, `refresh`, `selectDisplay`, `setFitToWindow`, `setInteractionMode`, `applyPreferences`, `connect`, `disconnect`, `close`) plus `discovered`, `discoveryFailed` and `backend(ScreenSharingViewerEvent)`. The two effects (discovery, the connection stream) share `CancelID.connection` with `cancelInFlight`, which replaces the generation counter. Endpoint side effects (fit, control requests) run synchronously on the main actor inside the reducer, keeping them ordered with the state change that caused them and free of effect races in tests. `preferencesRevision` increments only for changes the user made in this pane, so the pane persists exactly those and an applied registry update never echoes — a `TestStore` assertion rather than a closure convention.

## Migration steps

Each step compiles and passes on its own; they are ordered so the native path never changes observable behavior.

| Step | Change                                                                                                                                                                                                                                                                                                                     | Tests                                                                                                                                                                                                                                                                                                                         |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 0    | `ScreenSharingCore` target; `git mv` the files above; `@_exported import` from the media target; `swift-composable-architecture` 1.26.2 as a dependency of `CodevisorCoreMac`.                                                                                                                                             | Existing suites unchanged (tests of moved types add `@testable import ScreenSharingCore`).                                                                                                                                                                                                                                    |
| 1    | `ScreenSharingVideoSurface(mailbox:metrics:profile:)` replaces `init(peer:)`. `ScreenSharingMetalEncoder` accepts `kCVPixelFormatType_32BGRA` with a second pipeline (`screenFragmentBGRA`); `Textures` becomes a two-case enum; `TextureFrame` retains whichever planes were bound.                                       | New: BGRA and NV12 frames produce textures, an unsupported format returns nil (device-backed, no drawable). Existing coordinator/preparation tests unchanged.                                                                                                                                                                 |
| 2    | `ScreenSharingMessageChannel` + `ScreenSharingLocalChannel`; `ScreenSharingDataChannel` conforms; `ScreenSharingViewerClipboard` and the host control take the protocol.                                                                                                                                                   | New: local pair delivers in order, closing one side reports unavailability on both, `send` on a closed channel returns false. Clipboard transfer tests run against the local pair.                                                                                                                                            |
| 3    | `ScreenSharingViewingSession` contract; `NativeScreenSharingViewingSession` wraps `ScreenSharingPeer`; `NativeScreenSharingViewerBackend` absorbs signaling, heartbeats and recovery from the view model; `ScreenSharingViewerEndpoint` owns surface/control/clipboard/diagnostics. `ScreenSharingViewingPeer` is deleted. | The twelve `ScreenSharingViewerTests` cases that concern signaling order, viewer-id reuse, restart limits, stop-not-cancelled and the video watchdog move to `NativeScreenSharingViewerBackendTests` against the existing `SharingTransport` fixture and the repo `TestClock`.                                                |
| 4    | `ScreenSharingViewer` reducer replaces `ScreenSharingViewerModel`; `ScreenSharingPane` and `ScreenSharingToolbar` hold a `StoreOf<ScreenSharingViewer>`; the pane installs the native backend with `withDependencies`.                                                                                                     | New `ScreenSharingViewerReducerTests` with `TestStore` and a scripted fake backend: visibility suspend/resume, missing preferred display never falls back, mode retained across reconnect, control requested only after `.ready`, applied preferences do not echo, display change from another client requires a new connect. |

## Validation

- `swift test --package-path packages/swift --filter 'ScreenSharing'` — every screen-sharing suite in all four targets.
- `bun run swift:format:check && bun run swift:lint`.
- `bun run build:macos` — the app links the new target graph and Xcode resolves `ComposableArchitecture`.
- Tophat the shipped path in the dev app: open a Screen Sharing pane against a local Mac, connect, request control, transfer clipboard text, toggle Fit/Actual Size, hide and re-show the pane, and confirm the Connection Details popover still populates.
- Two-Mac rig runs are unaffected by design: the rig consumes `ScreenSharingPeer`, `ScreenSharingMetalView(mailbox:metrics:)` and `ScreenSharingControlChannel` directly, none of which change signature.

## Risks and decisions

- **TCA's build cost.** `@Reducer` and `@ObservableState` are macros; the first clean build compiles swift-syntax. Accepted for the control-plane ergonomics and `TestStore`; nothing on the frame or input path touches TCA.
- **Xcode's macro trust gate.** These are the project's first package dependencies that ship macro plugins, and `xcodebuild` refuses unapproved macros. Both command-line entry points (`scripts/xcodebuild.mjs` for `build:macos`/`build:ios`/`dev`, and `scripts/release/build-macos-xcode.sh`) pass `-skipMacroValidation`, trusting the pinned checkouts. Opening the project in Xcode itself asks once.
- **No TCA re-export.** `CodevisorCoreMac` does not `@_exported import ComposableArchitecture`: TCA re-exports swift-clocks, whose `TestClock` would shadow the repository's own `TestClock` in every test file that imports `CodevisorCoreMac`. The two app files that hold a store import TCA directly.
- **Two `TestClock`s.** swift-clocks' `TestClock` advances by yielding, which the repository's determinism rules forbid. The native backend keeps the repo's continuation-based `TestClock` through an injected `sleep`; the reducer needs no clock because all timing lives in the backend. `TestStore` assertions run under `withMainSerialExecutor`.
- **Reference types in reducer state.** `ScreenSharingViewerEndpoint` is a main-actor class held in state, equatable by identity. This is the documented TCA pattern for view handles and keeps the surface out of the action stream.
- **Access levels.** `package` symbols keep working across the new target boundary; tests of moved types need `@testable import ScreenSharingCore`.

## Out of scope, and what it unlocks

Not in this branch: any RFB code, a VNC pane type, Keychain credentials, audio, iOS, or splitting capture/codecs/render into further targets. After this lands, a VNC viewer is additive: a `ScreenSharingRFB` target (pure protocol, fixture-tested) and a `VNCScreenSharingViewerBackend` producing BGRA frames into a `ScreenSharingFrameMailbox`, with `capabilities` omitting `.control` lease semantics and mapping `ScreenSharingInputEvent` to keysyms. The pane, reducer, surface, renderer and clipboard transfer need no changes for it.
