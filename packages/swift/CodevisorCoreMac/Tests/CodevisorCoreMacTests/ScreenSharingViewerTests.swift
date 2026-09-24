import CodevisorClient
import CodevisorCore
import ScreenSharing
import CodevisorTestSupport
import ComposableArchitecture
import Foundation
import Testing
@testable import CodevisorCoreMac

/// The viewer's control plane against a scripted backend and endpoint client:
/// every transition is asserted exhaustively, including the lease child's,
/// and the endpoint calls (control messages, input) are checked on the client
/// they land on.
@MainActor
struct ScreenSharingViewerTests {
  private let display = ScreenSharingViewerFixtures.display
  private let second = ScreenSharingViewerFixtures.second

  @Test func discoveryFailureShowsTheServerMessage() async {
    await withMainSerialExecutor {
      let backend = FakeBackend(displays: [display])
      backend.discoveryFailure = "Screen Sharing is unavailable on this Mac."
      let store = makeStore(backend)
      await store.send(.paneAppeared) {
        $0.visible = true
        $0.phase = .loading
      }
      await store.receive(\.discoveryResponse.failure) {
        $0.phase = .failed
        $0.message = "Screen Sharing is unavailable on this Mac."
      }
      await store.send(.paneClosed) {
        $0.visible = false
        $0.phase = .suspended
      }
      await store.finish()
    }
  }

  @Test(arguments: [ScreenSharingViewer.InteractionMode.view, .control])
  func connectingKeepsTheLatestModeAndRequestsControlOnlyAfterReady(
    mode: ScreenSharingViewer.InteractionMode
  )
    async
  {
    await withMainSerialExecutor {
      let backend = FakeBackend(displays: [display])
      let client = FakeEndpointClient()
      let store = await makeConnectingStore(backend, client)
      await store.send(.interactionModeChanged(.view)) { $0.interactionMode = .view }
      await store.send(.interactionModeChanged(.control)) { $0.interactionMode = .control }
      if mode == .view { await store.send(.interactionModeChanged(.view)) { $0.interactionMode = .view } }
      let endpoint = backend.open()
      await store.receive(\.connectionEvent.opened) {
        $0.endpoint = endpoint
        $0.lease = ControlLease.State(endpoint: endpoint.id)
      }
      client.emit(.availability(true), to: endpoint.id)
      await store.receive(\.lease.event) { $0.lease?.available = true }
      expectNoDifference(client.messages(to: endpoint.id), [])
      backend.emit(.ready)
      await store.receive(\.connectionEvent.ready) { $0.phase = .viewing }
      if mode == .control {
        await store.receive(\.lease.controlRequested) {
          $0.lease?.wantsControl = true
          $0.lease?.requestID = UUID(0)
          $0.lease?.phase = .requesting
        }
        expectNoDifference(client.messages(to: endpoint.id), [.request(id: UUID(0))])
      } else {
        expectNoDifference(client.messages(to: endpoint.id), [])
      }
      #expect(store.state.interactionMode == mode)
      await store.send(.paneClosed) {
        $0.visible = false
        $0.endpoint = nil
        $0.lease = nil
        $0.phase = .suspended
      }
      await store.finish()
    }
  }

  /// 851-2340: each new endpoint gets the machine's Dynamic Resolution setting;
  /// the toolbar toggle flips it, bumps the revision the pane persists, and
  /// tells the live endpoint.
  @Test func dynamicResolutionReachesTheEndpointAndTheToggleFlipsIt() async {
    await withMainSerialExecutor {
      let backend = FakeBackend(displays: [display])
      let client = FakeEndpointClient()
      let store = await makeViewingStore(backend, client, channelAvailable: false)
      let endpoint = backend.endpoints[0]
      await awaitObserved { client.dynamicResolutions.count == 1 }
      #expect(client.dynamicResolutions.map(\.enabled) == [true])
      #expect(client.dynamicResolutions.first?.endpoint == endpoint.id)
      await store.send(.dynamicResolutionToggled) {
        $0.dynamicResolution = false
        $0.dynamicResolutionRevision = 1
      }
      await awaitObserved { client.dynamicResolutions.count == 2 }
      #expect(client.dynamicResolutions.map(\.enabled) == [true, false])
      await store.send(.paneClosed) {
        $0.visible = false
        $0.endpoint = nil
        $0.lease = nil
        $0.phase = .suspended
      }
      await store.finish()
    }
  }

  @Test func controlIsRequestedWhenTheChannelOpensAfterVideoUnlessViewWasChosen() async {
    await withMainSerialExecutor {
      let backend = FakeBackend(displays: [display])
      let client = FakeEndpointClient()
      let store = await makeViewingStore(backend, client, channelAvailable: false)
      let endpoint = backend.endpoints[0]
      expectNoDifference(client.messages(to: endpoint.id), [])
      await store.send(.interactionModeChanged(.view)) { $0.interactionMode = .view }
      await store.receive(\.lease.controlReleased) { $0.lease?.wantsControl = false }
      client.emit(.availability(true), to: endpoint.id)
      await store.receive(\.lease.event) { $0.lease?.available = true }
      expectNoDifference(client.messages(to: endpoint.id), [])
      await store.send(.interactionModeChanged(.control)) { $0.interactionMode = .control }
      await store.receive(\.lease.controlRequested) {
        $0.lease?.wantsControl = true
        $0.lease?.requestID = UUID(0)
        $0.lease?.phase = .requesting
      }
      expectNoDifference(client.messages(to: endpoint.id), [.request(id: UUID(0))])
      await store.send(.paneClosed) {
        $0.visible = false
        $0.endpoint = nil
        $0.lease = nil
        $0.phase = .suspended
      }
      await store.finish()
    }
  }

  @Test(arguments: [true, false])
  func deniedOrRevokedControlReturnsTheModeToView(grantFirst: Bool) async {
    await withMainSerialExecutor {
      let backend = FakeBackend(displays: [display])
      let client = FakeEndpointClient()
      let store = await makeViewingStore(backend, client)
      let endpoint = backend.endpoints[0]
      if grantFirst {
        let lease = UUID()
        client.emit(.message(.grant(request: UUID(0), lease: lease)), to: endpoint.id)
        await store.receive(\.lease.event) {
          $0.lease?.requestID = nil
          $0.lease?.lease = lease
          $0.lease?.phase = .controlling
        }
        expectNoDifference(client.beginInputs.map(\.lease), [lease])
        client.emit(.message(.revoked(lease: lease, reason: "Host ended control")), to: endpoint.id)
        await store.receive(\.lease.event) {
          $0.lease?.wantsControl = false
          $0.lease?.lease = nil
          $0.lease?.phase = .viewing
          $0.lease?.message = "Host ended control"
        }
      } else {
        client.emit(.message(.denied(request: UUID(0), reason: "Host denied control")), to: endpoint.id)
        await store.receive(\.lease.event) {
          $0.lease?.wantsControl = false
          $0.lease?.requestID = nil
          $0.lease?.phase = .viewing
          $0.lease?.message = "Host denied control"
        }
      }
      await store.receive(\.lease.delegate.released) { $0.interactionMode = .view }
      expectNoDifference(client.endInputs, [endpoint.id])
      #expect(store.state.interactionMode == .view)
      await store.send(.paneClosed) {
        $0.visible = false
        $0.endpoint = nil
        $0.lease = nil
        $0.phase = .suspended
      }
      await store.finish()
    }
  }

  @Test(arguments: [ScreenSharingViewer.InteractionMode.view, .control])
  func reconnectingReplacesTheEndpointAndPreservesTheMode(mode: ScreenSharingViewer.InteractionMode) async {
    await withMainSerialExecutor {
      let backend = FakeBackend(displays: [display])
      let client = FakeEndpointClient()
      let store = await makeViewingStore(backend, client, mode: mode)
      backend.emit(.reconnecting)
      await store.receive(\.connectionEvent.reconnecting) {
        $0.endpoint = nil
        $0.lease = nil
        $0.phase = .reconnecting
        $0.message = "Reconnecting to this Mac…"
      }
      let replacement = backend.open()
      await store.receive(\.connectionEvent.opened) {
        $0.endpoint = replacement
        $0.lease = ControlLease.State(endpoint: replacement.id)
      }
      client.emit(.availability(true), to: replacement.id)
      await store.receive(\.lease.event) { $0.lease?.available = true }
      backend.emit(.ready)
      await store.receive(\.connectionEvent.ready) {
        $0.phase = .viewing
        $0.message = nil
      }
      if mode == .control {
        await store.receive(\.lease.controlRequested) {
          $0.lease?.wantsControl = true
          $0.lease?.requestID = UUID(1)
          $0.lease?.phase = .requesting
        }
        expectNoDifference(client.messages(to: replacement.id), [.request(id: UUID(1))])
      } else {
        expectNoDifference(client.messages(to: replacement.id), [])
      }
      #expect(store.state.interactionMode == mode)
      expectNoDifference(backend.connections.count, 1)
      await store.send(.paneClosed) {
        $0.visible = false
        $0.endpoint = nil
        $0.lease = nil
        $0.phase = .suspended
      }
      await store.finish()
    }
  }

  @Test func hidingSuspendsAndReshowingRediscoversThenReconnects() async {
    await withMainSerialExecutor {
      let backend = FakeBackend(displays: [display])
      let client = FakeEndpointClient()
      let store = await makeViewingStore(backend, client)
      await store.send(.paneDisappeared) {
        $0.visible = false
        $0.endpoint = nil
        $0.lease = nil
        $0.phase = .suspended
      }
      expectNoDifference(backend.terminations.value, 1)
      backend.emit(.ready)  // a late event from the cancelled stream is never delivered
      await store.send(.paneAppeared) {
        $0.visible = true
        $0.phase = .loading
      }
      await store.receive(\.discoveryResponse.success) { $0.phase = .connecting }
      expectNoDifference(backend.connections, ["display", "display"])
      await store.send(.paneClosed) {
        $0.visible = false
        $0.phase = .suspended
      }
      await store.finish()
      expectNoDifference(backend.terminations.value, 2)
    }
  }

  @Test func selectingAnotherDisplayWhileConnectedReconnectsToIt() async {
    await withMainSerialExecutor {
      let backend = FakeBackend(displays: [display, second])
      let client = FakeEndpointClient()
      let store = await makeViewingStore(backend, client)
      await store.send(.displaySelected("second")) {
        $0.preferences.preferredDisplayId = "second"
        $0.selectedDisplayId = "second"
        $0.preferencesRevision = 2
        $0.endpoint = nil
        $0.lease = nil
        $0.phase = .connecting
      }
      expectNoDifference(backend.connections, ["display", "second"])
      await store.send(.displaySelected("unknown"))
      await store.send(.paneClosed) {
        $0.visible = false
        $0.phase = .suspended
      }
      await store.finish()
    }
  }

  @Test func theBackendEndingFailsWithItsMessage() async {
    await withMainSerialExecutor {
      let backend = FakeBackend(displays: [display])
      let client = FakeEndpointClient()
      let store = await makeViewingStore(backend, client)
      backend.emit(.ended("Screen sharing ended on the host Mac."))
      backend.end()
      await store.receive(\.connectionEvent.ended) {
        $0.endpoint = nil
        $0.lease = nil
        $0.phase = .failed
        $0.message = "Screen sharing ended on the host Mac."
      }
      await store.send(.retryButtonTapped) {
        $0.phase = .loading
        $0.message = nil
      }
      await store.receive(\.discoveryResponse.success) { $0.phase = .connecting }
      expectNoDifference(backend.connections.count, 2)
      await store.send(.paneClosed) {
        $0.visible = false
        $0.phase = .suspended
      }
      await store.finish()
    }
  }

  @Test func aSyncedDisplayReconnectsWithoutEchoingTheWrite() async {
    await withMainSerialExecutor {
      let backend = FakeBackend(displays: [display])
      let client = FakeEndpointClient()
      let store = await makeViewingStore(backend, client)
      var preferences = store.state.preferences
      await store.send(.preferencesSynced(preferences))
      #expect(store.state.preferencesRevision == 1 && backend.connections.count == 1)

      preferences.preferredDisplayId = "missing"
      await store.send(.preferencesSynced(preferences)) {
        $0.preferences = preferences
        $0.endpoint = nil
        $0.lease = nil
        $0.phase = .loading
      }
      await store.receive(\.discoveryResponse.success) {
        $0.preferences.preferredDisplayId = "display"
        $0.preferencesRevision = 2
        $0.phase = .connecting
      }
      #expect(backend.connections.count == 2)
      await store.send(.paneClosed) {
        $0.visible = false
        $0.phase = .suspended
      }
      await store.finish()
    }
  }

  private func makeStore(
    _ backend: FakeBackend, _ client: FakeEndpointClient = FakeEndpointClient(),
    preferences: ScreenSharingPanePreferences = .init()
  ) -> TestStoreOf<ScreenSharingViewer> {
    TestStore(initialState: ScreenSharingViewer.State(preferences: preferences)) {
      ScreenSharingViewer()
    } withDependencies: {
      $0[ScreenSharingViewerBackend.self] = backend.value
      $0[ScreenSharingEndpointClient.self] = client.value
      $0.continuousClock = Clocks.TestClock()
      $0.uuid = .incrementing
    }
  }

  /// Visible and connecting to the first display, which discovery remembered.
  private func makeConnectingStore(
    _ backend: FakeBackend, _ client: FakeEndpointClient
  ) async -> TestStoreOf<ScreenSharingViewer> {
    let store = makeStore(backend, client)
    await store.send(.paneAppeared) {
      $0.visible = true
      $0.phase = .loading
    }
    await store.receive(\.discoveryResponse.success) {
      $0.displays = backend.displays
      $0.preferences.preferredDisplayId = backend.displays.first?.id
      $0.preferencesRevision = 1
      $0.selectedDisplayId = backend.displays.first?.id
      $0.phase = .connecting
    }
    return store
  }

  /// Connected and viewing the first display in `mode`; with an available
  /// channel, `.control` has a request (id 0) pending.
  private func makeViewingStore(
    _ backend: FakeBackend, _ client: FakeEndpointClient,
    mode: ScreenSharingViewer.InteractionMode = .control, channelAvailable: Bool = true
  ) async -> TestStoreOf<ScreenSharingViewer> {
    let store = await makeConnectingStore(backend, client)
    if mode == .view { await store.send(.interactionModeChanged(.view)) { $0.interactionMode = .view } }
    let endpoint = backend.open()
    await store.receive(\.connectionEvent.opened) {
      $0.endpoint = endpoint
      $0.lease = ControlLease.State(endpoint: endpoint.id)
    }
    if channelAvailable {
      client.emit(.availability(true), to: endpoint.id)
      await store.receive(\.lease.event) { $0.lease?.available = true }
    }
    backend.emit(.ready)
    await store.receive(\.connectionEvent.ready) { $0.phase = .viewing }
    if mode == .control {
      await store.receive(\.lease.controlRequested) {
        $0.lease?.wantsControl = true
        if channelAvailable {
          $0.lease?.requestID = UUID(0)
          $0.lease?.phase = .requesting
        }
      }
    }
    return store
  }
}

/// A scripted backend: discovery answers from a list (or fails), and each
/// connection hands the test the stream's continuation. Endpoints it opens
/// are real, over fake sessions and surfaces.
@MainActor
final class FakeBackend {
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
      connect: { [self] display in
        await MainActor.run {
          connections.append(display)
          let terminations = terminations
          return AsyncStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { _ in terminations.withValue { $0 += 1 } }
          }
        }
      },
      discover: { [self] in
        try await MainActor.run {
          if let failure = discoveryFailure { throw Failure(failure) }
          return displays
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
    sessions.append(session)
    surfaces.append(surface)
    endpoints.append(endpoint)
    continuation?.yield(.opened(endpoint))
    return endpoint
  }

  func emit(_ event: ScreenSharingViewerEvent) { continuation?.yield(event) }
  func end() { continuation?.finish() }

  private struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }
}
