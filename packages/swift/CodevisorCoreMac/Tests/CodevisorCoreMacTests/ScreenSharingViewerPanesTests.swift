import ComposableArchitecture
import Foundation
import ScreenSharing
import Testing

@testable import CodevisorCoreMac

@MainActor
struct ScreenSharingViewerPanesTests {
  @Test func anotherPaneGivingUpControlOrItsPictureLeavesThisPanesControlRunning() async {
    await withMainSerialExecutor {
      let (window, other) = (ScreenSharingViewerHarness(), ScreenSharingViewerHarness())
      let endpoint = await window.view()
      let lease = await window.grantControl(to: endpoint)
      let elsewhere = await other.view()
      _ = await other.grantControl(to: elsewhere)

      await other.store.send(.hidden) { $0.visible = false }
      await other.store.receive(\.lease.suspended) {
        $0.lease?.wantsControl = false
        $0.lease?.lease = nil
        $0.lease?.phase = .viewing
      }
      await window.clock.advance(by: .seconds(1))
      await window.store.receive(\.lease.heartbeatTick)
      expectNoDifference(window.client.messages(to: endpoint.id).last, .heartbeat(lease: lease))

      await other.finish()
      await window.clock.advance(by: .seconds(1))
      await window.store.receive(\.lease.heartbeatTick)
      window.client.emit(.message(.revoked(lease: lease, reason: "Control released.")), to: endpoint.id)
      await window.store.receive(\.lease.event) {
        $0.lease?.wantsControl = false
        $0.lease?.lease = nil
        $0.lease?.phase = .viewing
        $0.lease?.message = "Control released."
      }
      await window.store.receive(\.lease.delegate.released)
      await window.finish()
    }
  }

  @Test func anotherPaneAskingForControlLeavesThisPanesRequestDeadlineRunning() async {
    await withMainSerialExecutor {
      let (window, other) = (ScreenSharingViewerHarness(), ScreenSharingViewerHarness())
      await window.view()
      await other.view()

      await window.clock.advance(by: .seconds(3))
      await window.store.receive(\.lease.requestTimedOut) {
        $0.lease?.requestID = UUID(1)
        $0.lease?.retriedRequest = true
        $0.lease?.unansweredRequests = [UUID(0)]
      }
      await other.finish()
      await window.finish()
    }
  }
}
