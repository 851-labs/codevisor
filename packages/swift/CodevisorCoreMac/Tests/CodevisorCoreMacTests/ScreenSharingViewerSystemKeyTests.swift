import CodevisorTestSupport
import ComposableArchitecture
import Foundation
import ScreenSharing
import Testing

@testable import CodevisorCoreMac

@MainActor
struct ScreenSharingViewerSystemKeyTests {
  @Test func aSystemKeyPressedWhileViewingAsksForControlAndHandsTheKeyOver() async {
    await withMainSerialExecutor {
      let harness = ScreenSharingViewerHarness()
      await harness.connect()
      await harness.store.send(.systemKeyTapped(.apps))
      #expect(harness.client.systemKeys.isEmpty)
      await harness.store.send(.interactionModeChanged(.view)) { $0.interactionMode = .view }
      let endpoint = await harness.open()
      await harness.goLive(expectingRequest: nil)

      await harness.store.send(.systemKeyTapped(.missionControl)) { $0.interactionMode = .control }
      await harness.store.receive(\.lease.controlRequested) {
        $0.lease?.wantsControl = true
        $0.lease?.requestID = UUID(0)
        $0.lease?.phase = .requesting
      }

      expectNoDifference(harness.client.systemKeys.map(\.key), [.missionControl])
      expectNoDifference(harness.client.messages(to: endpoint.id), [.request(id: UUID(0))])
      await harness.finish()
    }
  }

  @Test func aSystemKeyPressedWhileControllingGoesStraightThrough() async {
    await withMainSerialExecutor {
      let harness = ScreenSharingViewerHarness()
      let endpoint = await harness.view()
      _ = await harness.grantControl(to: endpoint)

      await harness.store.send(.systemKeyTapped(.desktop))

      expectNoDifference(harness.client.systemKeys.map(\.key), [.desktop])
      expectNoDifference(harness.client.messages(to: endpoint.id), [.request(id: UUID(0))])
      await harness.finish()
    }
  }
}
