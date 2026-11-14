import CodevisorTestSupport
import ComposableArchitecture
import Foundation
import ScreenSharing
import Testing

@testable import CodevisorCoreMac

@MainActor
struct ScreenSharingViewerVisibilityTests {
  @Test func hidingGivesControlBackAndShowingAsksForItAgain() async {
    await withMainSerialExecutor {
      let harness = ScreenSharingViewerHarness()
      let endpoint = await harness.view()
      let lease = await harness.grantControl(to: endpoint)

      await harness.store.send(.hidden) { $0.visible = false }
      await harness.store.receive(\.lease.suspended) {
        $0.lease?.wantsControl = false
        $0.lease?.lease = nil
        $0.lease?.phase = .viewing
      }
      await harness.store.send(.hidden)
      await harness.store.send(.shown) { $0.visible = true }
      await harness.store.receive(\.lease.controlRequested) {
        $0.lease?.wantsControl = true
        $0.lease?.requestID = UUID(1)
        $0.lease?.phase = .requesting
      }

      expectNoDifference(
        harness.client.messages(to: endpoint.id),
        [.request(id: UUID(0)), .release(lease: lease), .request(id: UUID(1))])
      #expect(harness.store.state.endpoint == endpoint, "hiding a surface never drops its picture")
      await harness.finish()
    }
  }

  @Test func aSurfaceThatGoesLiveWhileHiddenAsksForControlOnlyWhenShown() async {
    await withMainSerialExecutor {
      let harness = ScreenSharingViewerHarness()
      await harness.connect()
      let endpoint = await harness.open()
      await harness.store.send(.hidden) { $0.visible = false }
      await harness.store.receive(\.lease.suspended)
      await harness.surface { $0.connection = .live }
      expectNoDifference(harness.client.messages(to: endpoint.id), [])

      await harness.store.send(.shown) { $0.visible = true }
      await harness.store.receive(\.lease.controlRequested) {
        $0.lease?.wantsControl = true
        $0.lease?.requestID = UUID(0)
        $0.lease?.phase = .requesting
      }
      await harness.finish()
    }
  }
}
