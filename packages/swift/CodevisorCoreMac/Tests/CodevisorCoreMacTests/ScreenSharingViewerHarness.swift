import CodevisorClient
import CodevisorCore
import ComposableArchitecture
import Foundation
import ScreenSharingConnection

@testable import CodevisorCoreMac

@MainActor
final class ScreenSharingViewerHarness {
  static let machine = "croissant"

  let client = FakeEndpointClient()
  let store: TestStoreOf<ScreenSharingViewer>
  private let asked = LockIsolated<[String]>([])
  private var snapshot = ScreenSharingSurfaceSnapshot()

  init(preferences: ScreenSharingPanePreferences = .init()) {
    let (asked, endpoints) = (asked, client.value)
    store = TestStore(initialState: ScreenSharingViewer.State(machineName: Self.machine, preferences: preferences)) {
      ScreenSharingViewer()
    } withDependencies: {
      $0[ScreenSharingSurfaceClient.self] = ScreenSharingSurfaceClient(
        retry: { asked.withValue { $0.append("retry") } },
        takePicture: { asked.withValue { $0.append("take picture") } },
        switchDisplay: { display in asked.withValue { $0.append("switch to \(display)") } })
      $0[ScreenSharingEndpointClient.self] = endpoints
      $0.continuousClock = Clocks.TestClock<Duration>()
      $0.uuid = .incrementing
    }
  }

  var askedOfTheConnection: [String] { asked.value }

  static func endpoint(display: String? = nil) -> ScreenSharingViewerEndpoint {
    ScreenSharingViewerEndpoint(session: FakeMediaSession(), surface: FakeSurface(), displayId: display)
  }

  func surface(
    _ change: (inout ScreenSharingSurfaceSnapshot) -> Void,
    then expected: @escaping (inout ScreenSharingViewer.State) -> Void = { _ in }
  ) async {
    change(&snapshot)
    let snapshot = snapshot
    await store.send(.surfaceChanged(snapshot)) {
      $0.surface = snapshot
      expected(&$0)
    }
  }

  func connect(showing displays: [ServerScreenSharingDisplay] = [ScreenSharingViewerFixtures.display]) async {
    await store.send(.shown) { $0.visible = true }
    await surface {
      $0.connection = .connecting(.waitingForVideo)
      $0.displays = displays
      $0.displayId = displays.first?.id
    }
  }

  @discardableResult
  func open(channelAvailable: Bool = true) async -> ScreenSharingViewerEndpoint {
    let endpoint = Self.endpoint()
    await surface {
      $0.picture = .here(endpoint)
    } then: {
      $0.lease = ControlLease.State(endpoint: endpoint.id)
      $0.picturesTaken += 1
    }
    guard channelAvailable else { return endpoint }

    client.emit(.availability(true), to: endpoint.id)
    await store.receive(\.lease.event) { $0.lease?.available = true }
    return endpoint
  }

  func goLive(expectingRequest request: UUID?) async {
    await surface { $0.connection = .live }
    guard store.state.interactionMode == .control else { return }

    await store.receive(\.lease.controlRequested) {
      $0.lease?.wantsControl = true
      guard let request else { return }

      $0.lease?.requestID = request
      $0.lease?.phase = .requesting
    }
  }

  @discardableResult
  func view(
    _ mode: ScreenSharingViewer.InteractionMode = .control, channelAvailable: Bool = true
  ) async -> ScreenSharingViewerEndpoint {
    await connect()
    if mode == .view { await store.send(.interactionModeChanged(.view)) { $0.interactionMode = .view } }
    let endpoint = await open(channelAvailable: channelAvailable)
    await goLive(expectingRequest: channelAvailable ? UUID(0) : nil)
    return endpoint
  }

  func grantControl(to endpoint: ScreenSharingViewerEndpoint, request: UUID = UUID(0)) async -> UUID {
    let lease = UUID()
    client.emit(.message(.grant(request: request, lease: lease)), to: endpoint.id)
    await store.receive(\.lease.event) {
      $0.lease?.requestID = nil
      $0.lease?.lease = lease
      $0.lease?.phase = .controlling
    }
    return lease
  }

  func finish() async {
    if snapshot != ScreenSharingSurfaceSnapshot() {
      await surface {
        $0 = ScreenSharingSurfaceSnapshot()
      } then: {
        $0.lease = nil
      }
    }
    await store.finish()
  }
}
