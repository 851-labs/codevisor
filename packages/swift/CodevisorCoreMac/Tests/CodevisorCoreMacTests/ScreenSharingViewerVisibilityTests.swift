import CodevisorTestSupport
import ComposableArchitecture
import Foundation
import ScreenSharing
import Testing
@testable import CodevisorCoreMac

@MainActor
struct ScreenSharingViewerVisibilityTests {
  private let display = ScreenSharingViewerFixtures.display
  private let viewer = ScreenSharingViewerTests()

  @Test func hidingKeepsTheConnectionAndShowingAsksForControlAgain() async {
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
      await store.send(.paneDisappeared) { $0.visible = false }
      await store.receive(\.lease.suspended) {
        $0.lease?.wantsControl = false
        $0.lease?.lease = nil
        $0.lease?.phase = .viewing
      }
      await store.send(.paneAppeared) { $0.visible = true }
      await store.receive(\.lease.controlRequested) {
        $0.lease?.wantsControl = true
        $0.lease?.requestID = UUID(1)
        $0.lease?.phase = .requesting
      }
      expectNoDifference(
        client.messages(to: endpoint.id), [.request(id: UUID(0)), .release(lease: lease), .request(id: UUID(1))])
      expectNoDifference(backend.connections, ["display"])
      expectNoDifference(backend.terminations.value, 0)
      await store.send(.paneClosed) {
        $0.visible = false
        $0.endpoint = nil
        $0.lease = nil
        $0.phase = .suspended
      }
      await store.finish()
    }
  }

  @Test func aPaneHiddenPastTheGraceLetsItsConnectionGo() async {
    await withMainSerialExecutor {
      let backend = FakeBackend(displays: [display])
      let client = FakeEndpointClient()
      let clock = Clocks.TestClock()
      let store = await viewer.makeViewingStore(backend, client, mode: .view, clock: clock)
      await store.send(.paneDisappeared) { $0.visible = false }
      await store.receive(\.lease.suspended)
      await clock.advance(by: ScreenSharingViewer.hiddenGrace - .seconds(1))
      expectNoDifference(backend.terminations.value, 0)
      await clock.advance(by: .seconds(1))
      await store.receive(\.hiddenGraceExpired) {
        $0.endpoint = nil
        $0.lease = nil
        $0.phase = .suspended
      }
      expectNoDifference(backend.terminations.value, 1)
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
}
