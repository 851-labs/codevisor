import CodevisorClient
import CodevisorCore
import CodevisorScreenSharing
import CodevisorTestSupport
import ComposableArchitecture
import ConcurrencyExtras
import Foundation
import Testing
@testable import CodevisorCoreMac

/// The viewer's control plane against a scripted backend: every transition is
/// asserted exhaustively, and the endpoint side effects (fit, control
/// requests) are checked on the fake surface and channel they land on.
@MainActor
struct ScreenSharingViewerTests {
  private let display = ScreenSharingViewerFixtures.display
  private let second = ScreenSharingViewerFixtures.second

  @Test func aMissingPreferredDisplayNeverSelectsAnotherDisplay() async {
    await withMainSerialExecutor {
      let backend = FakeBackend(displays: [display])
      let store = makeStore(backend, preferences: .init(preferredDisplayId: "missing"))
      await store.send(.setVisible(true)) {
        $0.visible = true; $0.phase = .loading
      }
      await store.receive(.discovered([display])) {
        $0.displays = [self.display]
        $0.phase = .failed
        $0.message = "The selected display is unavailable. Choose another display to connect."
      }
      #expect(backend.connections.isEmpty)
      await store.send(.close) {
        $0.visible = false; $0.phase = .suspended
      }
    }
  }

  @Test func discoveryFailureShowsTheServerMessage() async {
    await withMainSerialExecutor {
      let backend = FakeBackend(displays: [display])
      backend.discoveryFailure = "Screen Sharing is unavailable on this Mac."
      let store = makeStore(backend)
      await store.send(.setVisible(true)) {
        $0.visible = true; $0.phase = .loading
      }
      await store.receive(.discoveryFailed("Screen Sharing is unavailable on this Mac.")) {
        $0.phase = .failed
        $0.message = "Screen Sharing is unavailable on this Mac."
      }
      await store.send(.close) {
        $0.visible = false; $0.phase = .suspended
      }
    }
  }

  @Test(arguments: [ScreenSharingViewer.InteractionMode.view, .control])
  func connectingKeepsTheLatestModeAndFitAndRequestsControlOnlyAfterReady(
    mode: ScreenSharingViewer.InteractionMode
  )
    async
  {
    await withMainSerialExecutor {
      let backend = FakeBackend(displays: [display])
      let store = await makeReadyStore(backend)
      await store.send(.setInteractionMode(.view)) { $0.interactionMode = .view }
      await store.send(.connect) {
        $0.preferences.preferredDisplayId = "display"
        $0.preferencesRevision = 1
        $0.wantsConnection = true
        $0.phase = .connecting
      }
      await store.send(.setInteractionMode(.control)) { $0.interactionMode = .control }
      if mode == .view { await store.send(.setInteractionMode(.view)) { $0.interactionMode = .view } }
      await store.send(.setFitToWindow(false)) {
        $0.preferences.fitToWindow = false; $0.preferencesRevision = 2
      }
      let endpoint = backend.open()
      await store.receive(.backend(.opened(endpoint))) { $0.endpoint = endpoint }
      #expect(backend.surfaces[0].fitToWindow == false)
      #expect(backend.sessions[0].controlChannel.sent.isEmpty)
      backend.sessions[0].controlChannel.isAvailable = true
      backend.emit(.ready)
      await store.receive(.backend(.ready)) { $0.phase = .viewing }
      #expect(endpoint.control.state == (mode == .control ? .requesting : .viewing))
      #expect(backend.sessions[0].controlChannel.sent.count == (mode == .control ? 1 : 0))
      #expect(store.state.interactionMode == mode)
      await store.send(.close) {
        $0.visible = false; $0.wantsConnection = false; $0.endpoint = nil; $0.phase = .suspended
      }
      backend.closeAll()
    }
  }

  @Test func controlIsRequestedWhenTheChannelOpensAfterVideoUnlessViewWasChosen() async {
    await withMainSerialExecutor {
      let backend = FakeBackend(displays: [display])
      let store = await makeViewingStore(backend, channelAvailable: false)
      let channel = backend.sessions[0].controlChannel
      let endpoint = backend.endpoints[0]
      #expect(channel.sent.isEmpty && endpoint.control.state == .viewing)
      await store.send(.setInteractionMode(.view)) { $0.interactionMode = .view }
      channel.isAvailable = true
      #expect(channel.sent.isEmpty)
      await store.send(.setInteractionMode(.control)) { $0.interactionMode = .control }
      #expect(endpoint.control.state == .requesting && channel.sent.count == 1)
      await store.send(.close) {
        $0.visible = false; $0.wantsConnection = false; $0.endpoint = nil; $0.phase = .suspended
      }
      backend.closeAll()
    }
  }

  @Test(arguments: [true, false])
  func deniedOrRevokedControlReturnsTheModeToView(grantFirst: Bool) async {
    await withMainSerialExecutor {
      let backend = FakeBackend(displays: [display])
      let store = await makeViewingStore(backend)
      let channel = backend.sessions[0].controlChannel
      let endpoint = backend.endpoints[0]
      guard case .request(let request)? = channel.sent.first else {
        Issue.record("Missing control request"); backend.closeAll(); return
      }
      if grantFirst {
        let lease = UUID()
        channel.deliver(.grant(request: request, lease: lease))
        #expect(endpoint.control.state == .controlling && backend.surfaces[0].inputActive)
        channel.deliver(.revoked(lease: lease, reason: "Host ended control"))
      } else {
        channel.deliver(.denied(request: request, reason: "Host denied control"))
      }
      #expect(endpoint.control.state == .viewing && !backend.surfaces[0].inputActive)
      await store.receive(.backend(.controlReleased)) { $0.interactionMode = .view }
      await store.send(.setFitToWindow(false)) {
        $0.preferences.fitToWindow = false; $0.preferencesRevision = 2
      }
      #expect(store.state.interactionMode == .view)
      await store.send(.close) {
        $0.visible = false; $0.wantsConnection = false; $0.endpoint = nil; $0.phase = .suspended
      }
      backend.closeAll()
    }
  }

  @Test(arguments: [ScreenSharingViewer.InteractionMode.view, .control])
  func reconnectingReplacesTheEndpointAndPreservesTheMode(mode: ScreenSharingViewer.InteractionMode) async {
    await withMainSerialExecutor {
      let backend = FakeBackend(displays: [display])
      let store = await makeViewingStore(backend, mode: mode)
      backend.emit(.reconnecting)
      await store.receive(.backend(.reconnecting)) {
        $0.endpoint = nil
        $0.phase = .reconnecting
        $0.message = "Reconnecting to this Mac…"
      }
      let replacement = backend.open()
      await store.receive(.backend(.opened(replacement))) { $0.endpoint = replacement }
      backend.sessions[1].controlChannel.isAvailable = true
      backend.emit(.ready)
      await store.receive(.backend(.ready)) {
        $0.phase = .viewing; $0.message = nil
      }
      #expect(store.state.interactionMode == mode)
      #expect(replacement.control.state == (mode == .control ? .requesting : .viewing))
      #expect(backend.sessions[1].controlChannel.sent.count == (mode == .control ? 1 : 0))
      #expect(backend.connections.count == 1)
      await store.send(.close) {
        $0.visible = false; $0.wantsConnection = false; $0.endpoint = nil; $0.phase = .suspended
      }
      backend.closeAll()
    }
  }

  @Test func hidingSuspendsAndReshowingRediscoversThenReconnects() async {
    await withMainSerialExecutor {
      let backend = FakeBackend(displays: [display])
      let store = await makeViewingStore(backend)
      await store.send(.setVisible(false)) {
        $0.visible = false; $0.endpoint = nil; $0.phase = .suspended
      }
      #expect(backend.terminations.value == 1)
      backend.emit(.ready)  // a late event from the cancelled stream is never delivered
      await store.send(.setVisible(true)) {
        $0.visible = true; $0.phase = .loading
      }
      await store.receive(.discovered([display])) { $0.phase = .connecting }
      #expect(backend.connections == ["display", "display"])
      await store.send(.close) {
        $0.visible = false; $0.wantsConnection = false; $0.phase = .suspended
      }
      #expect(backend.terminations.value == 2)
      backend.closeAll()
    }
  }

  @Test func selectingAnotherDisplayWhileConnectedReconnectsToIt() async {
    await withMainSerialExecutor {
      let backend = FakeBackend(displays: [display, second])
      let store = await makeViewingStore(backend)
      await store.send(.selectDisplay("second")) {
        $0.preferences.preferredDisplayId = "second"
        $0.selectedDisplayId = "second"
        $0.preferencesRevision = 2
        $0.endpoint = nil
        $0.phase = .connecting
      }
      #expect(backend.connections == ["display", "second"])
      await store.send(.disconnect) {
        $0.wantsConnection = false; $0.phase = .ready
      }
      await store.send(.selectDisplay("display")) {
        $0.preferences.preferredDisplayId = "display"
        $0.selectedDisplayId = "display"
        $0.preferencesRevision = 3
      }
      #expect(backend.connections.count == 2)
      await store.send(.close) {
        $0.visible = false; $0.phase = .suspended
      }
      backend.closeAll()
    }
  }

  @Test func theBackendEndingFailsWithItsMessage() async {
    await withMainSerialExecutor {
      let backend = FakeBackend(displays: [display])
      let store = await makeViewingStore(backend)
      backend.emit(.ended("Screen sharing ended on the host Mac."))
      backend.end()
      await store.receive(.backend(.ended("Screen sharing ended on the host Mac."))) {
        $0.endpoint = nil
        $0.phase = .failed
        $0.message = "Screen sharing ended on the host Mac."
      }
      await store.send(.refresh) {
        $0.phase = .loading; $0.message = nil
      }
      await store.receive(.discovered([display])) { $0.phase = .connecting }
      #expect(backend.connections.count == 2)
      await store.send(.close) {
        $0.visible = false; $0.wantsConnection = false; $0.phase = .suspended
      }
      backend.closeAll()
    }
  }

  @Test func appliedPreferencesUpdateTheLiveSurfaceWithoutEchoOrReconnect() async {
    await withMainSerialExecutor {
      let backend = FakeBackend(displays: [display])
      let store = await makeViewingStore(backend)
      var preferences = store.state.preferences
      preferences.fitToWindow = false
      await store.send(.applyPreferences(preferences)) { $0.preferences = preferences }
      await store.send(.applyPreferences(preferences))
      #expect(backend.surfaces[0].fitToWindow == false)
      #expect(store.state.preferencesRevision == 1 && backend.connections.count == 1)

      preferences.preferredDisplayId = "missing"
      await store.send(.applyPreferences(preferences)) {
        $0.preferences = preferences
        $0.wantsConnection = false
        $0.endpoint = nil
        $0.phase = .loading
      }
      await store.receive(.discovered([display])) {
        $0.selectedDisplayId = nil
        $0.phase = .failed
        $0.message = "The selected display is unavailable. Choose another display to connect."
      }
      #expect(backend.connections.count == 1 && store.state.preferencesRevision == 1)
      await store.send(.close) {
        $0.visible = false; $0.phase = .suspended
      }
      backend.closeAll()
    }
  }

  private func makeStore(
    _ backend: FakeBackend, preferences: ScreenSharingPanePreferences = .init()
  ) -> TestStoreOf<ScreenSharingViewer> {
    TestStore(initialState: ScreenSharingViewer.State(preferences: preferences)) {
      ScreenSharingViewer()
    } withDependencies: {
      $0.screenSharingViewerBackend = backend.value
    }
  }

  /// Visible with the first display selected and nothing connected.
  private func makeReadyStore(_ backend: FakeBackend) async -> TestStoreOf<ScreenSharingViewer> {
    let store = makeStore(backend)
    await store.send(.setVisible(true)) {
      $0.visible = true; $0.phase = .loading
    }
    await store.receive(.discovered(backend.displays)) {
      $0.displays = backend.displays
      $0.selectedDisplayId = backend.displays.first?.id
      $0.phase = .ready
    }
    return store
  }

  /// Connected and viewing the first display in `mode`, control requested when the mode asks for it.
  private func makeViewingStore(
    _ backend: FakeBackend, mode: ScreenSharingViewer.InteractionMode = .control, channelAvailable: Bool = true
  ) async -> TestStoreOf<ScreenSharingViewer> {
    let store = await makeReadyStore(backend)
    if mode == .view { await store.send(.setInteractionMode(.view)) { $0.interactionMode = .view } }
    await store.send(.connect) {
      $0.preferences.preferredDisplayId = backend.displays.first?.id
      $0.preferencesRevision = 1
      $0.wantsConnection = true
      $0.phase = .connecting
    }
    let endpoint = backend.open()
    await store.receive(.backend(.opened(endpoint))) { $0.endpoint = endpoint }
    backend.sessions.last?.controlChannel.isAvailable = channelAvailable
    backend.emit(.ready)
    await store.receive(.backend(.ready)) { $0.phase = .viewing }
    return store
  }
}

/// A scripted backend: discovery answers from a list (or fails), and each
/// connection hands the test the stream's continuation. Endpoints it opens
/// are real, over fake sessions and surfaces, and their released control
/// leases flow back as events exactly as the native backend reports them.
@MainActor
private final class FakeBackend {
  var displays: [ServerScreenSharingDisplay]
  var discoveryFailure: String?
  private(set) var connections: [String] = []
  let terminations = LockIsolated(0)
  private(set) var sessions: [FakeMediaSession] = []
  private(set) var surfaces: [FakeSurface] = []
  private(set) var endpoints: [ScreenSharingViewerEndpoint] = []
  private var continuation: AsyncStream<ScreenSharingViewerEvent>.Continuation?

  init(displays: [ServerScreenSharingDisplay]) { self.displays = displays }

  var value: ScreenSharingViewerBackend {
    ScreenSharingViewerBackend(
      discover: { [self] in
        try await MainActor.run {
          if let failure = discoveryFailure { throw Failure(failure) }
          return displays
        }
      },
      connect: { [self] display in
        connections.append(display)
        let terminations = terminations
        return AsyncStream { continuation in
          self.continuation = continuation
          continuation.onTermination = { _ in terminations.withValue { $0 += 1 } }
        }
      })
  }

  /// Opens a new endpoint on the current stream and reports it.
  @discardableResult
  func open() -> ScreenSharingViewerEndpoint {
    let session = FakeMediaSession()
    let surface = FakeSurface()
    session.surface = surface
    let endpoint = ScreenSharingViewerEndpoint(session: session, surface: surface)
    endpoint.control.onReleased = { [weak self] in self?.continuation?.yield(.controlReleased) }
    sessions.append(session)
    surfaces.append(surface)
    endpoints.append(endpoint)
    continuation?.yield(.opened(endpoint))
    return endpoint
  }

  func emit(_ event: ScreenSharingViewerEvent) { continuation?.yield(event) }
  func end() { continuation?.finish() }
  func closeAll() { for endpoint in endpoints { endpoint.close() } }

  private struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }
}
