import CodevisorTestSupport
import ComposableArchitecture
import Foundation
import ScreenSharing
import Testing
@testable import CodevisorCoreMac

/// The Apps, Mission Control and Desktop buttons (851-2469, 851-2479), on the viewer's helpers.
@MainActor
struct ScreenSharingViewerSystemKeyTests {
  private let display = ScreenSharingViewerFixtures.display
  private let viewer = ScreenSharingViewerTests()

  /// 851-2479: the system-key buttons are always enabled. Pressed while viewing, one switches to
  /// Control and asks for it; the endpoint holds the key until the grant. Pressed while connecting
  /// (no live video yet) it does nothing.
  @Test func aSystemKeyPressedWhileViewingAsksForControlAndHandsTheKeyOver() async {
    await withMainSerialExecutor {
      let backend = FakeBackend(displays: [display])
      let client = FakeEndpointClient()
      let store = await viewer.makeConnectingStore(backend, client)
      await store.send(.systemKeyTapped(.apps))
      #expect(client.systemKeys.isEmpty)
      await store.send(.interactionModeChanged(.view)) { $0.interactionMode = .view }
      let endpoint = backend.open()
      await store.receive(\.connectionEvent.opened) {
        $0.endpoint = endpoint
        $0.lease = ControlLease.State(endpoint: endpoint.id)
      }
      client.emit(.availability(true), to: endpoint.id)
      await store.receive(\.lease.event) { $0.lease?.available = true }
      backend.emit(.ready)
      await store.receive(\.connectionEvent.ready) { $0.phase = .viewing }
      await store.send(.systemKeyTapped(.missionControl)) { $0.interactionMode = .control }
      await store.receive(\.lease.controlRequested) {
        $0.lease?.wantsControl = true
        $0.lease?.requestID = UUID(0)
        $0.lease?.phase = .requesting
      }
      expectNoDifference(client.systemKeys.map(\.key), [.missionControl])
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

  @Test func aSystemKeyPressedWhileControllingGoesStraightThrough() async {
    await withMainSerialExecutor {
      let backend = FakeBackend(displays: [display])
      let client = FakeEndpointClient()
      let store = await viewer.makeViewingStore(backend, client)
      let endpoint = backend.endpoints[0]
      let lease = UUID()
      client.emit(.message(.grant(request: UUID(0), lease: lease)), to: endpoint.id)
      await store.receive(\.lease.event) {
        $0.lease?.requestID = nil
        $0.lease?.lease = lease
        $0.lease?.phase = .controlling
      }
      await store.send(.systemKeyTapped(.desktop))
      expectNoDifference(client.systemKeys.map(\.key), [.desktop])
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
}
