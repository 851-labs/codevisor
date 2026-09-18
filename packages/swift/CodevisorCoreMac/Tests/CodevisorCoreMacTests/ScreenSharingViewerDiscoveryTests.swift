import CodevisorClient
import CodevisorCore
import ScreenSharing
import ComposableArchitecture
import CustomDump
import Foundation
import Testing
@testable import CodevisorCoreMac

/// Which display a new tab connects to: the one the pane last used when it is
/// still listed, else the first — and the preference is rewritten only when
/// the choice changed.
@MainActor
struct ScreenSharingViewerDiscoveryTests {
  private let display = ScreenSharingViewerFixtures.display
  private let second = ScreenSharingViewerFixtures.second

  @Test func aStalePreferenceFallsBackToTheFirstDisplayAndConnects() async {
    await withMainSerialExecutor {
      let backend = FakeBackend(displays: [display, second])
      let store = makeStore(backend, preferences: .init(preferredDisplayId: "missing"))
      await store.send(.paneAppeared) {
        $0.visible = true
        $0.phase = .loading
      }
      await store.receive(\.discoveryResponse.success) {
        $0.displays = [self.display, self.second]
        $0.preferences.preferredDisplayId = "display"
        $0.preferencesRevision = 1
        $0.selectedDisplayId = "display"
        $0.phase = .connecting
      }
      expectNoDifference(backend.connections, ["display"])
      await store.send(.paneClosed) {
        $0.visible = false
        $0.phase = .suspended
      }
      await store.finish()
    }
  }

  @Test func aRememberedDisplayIsConnectedWithoutRewritingThePreference() async {
    await withMainSerialExecutor {
      let backend = FakeBackend(displays: [display, second])
      let store = makeStore(backend, preferences: .init(preferredDisplayId: "second"))
      await store.send(.paneAppeared) {
        $0.visible = true
        $0.phase = .loading
      }
      await store.receive(\.discoveryResponse.success) {
        $0.displays = [self.display, self.second]
        $0.selectedDisplayId = "second"
        $0.phase = .connecting
      }
      expectNoDifference(backend.connections, ["second"])
      #expect(store.state.preferencesRevision == 0)
      await store.send(.paneClosed) {
        $0.visible = false
        $0.phase = .suspended
      }
      await store.finish()
    }
  }

  private func makeStore(
    _ backend: FakeBackend, preferences: ScreenSharingPanePreferences = .init()
  ) -> TestStoreOf<ScreenSharingViewer> {
    TestStore(initialState: ScreenSharingViewer.State(preferences: preferences)) {
      ScreenSharingViewer()
    } withDependencies: {
      $0[ScreenSharingViewerBackend.self] = backend.value
      $0[ScreenSharingEndpointClient.self] = FakeEndpointClient().value
      $0.continuousClock = Clocks.TestClock()
      $0.uuid = .incrementing
    }
  }
}
