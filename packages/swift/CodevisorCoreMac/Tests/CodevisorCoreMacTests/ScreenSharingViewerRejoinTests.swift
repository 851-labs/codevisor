import CodevisorClient
import ComposableArchitecture
import CustomDump
import Foundation
import Testing
@testable import CodevisorCoreMac

@MainActor
struct ScreenSharingViewerRejoinTests {
  private let display = ScreenSharingViewerFixtures.display
  private let viewer = ScreenSharingViewerTests()

  @Test func aFailedPaneRejoinsOnceTheDesktopStreamsElsewhere() async {
    await withMainSerialExecutor {
      let backend = FakeBackend(displays: [display])
      backend.discoveryFailure = "Check that it's online and connected to the internet."
      let clock = Clocks.TestClock()
      let store = viewer.makeStore(backend, clock: clock)
      await store.send(.paneAppeared) {
        $0.visible = true
        $0.phase = .loading
      }
      await store.receive(\.discoveryResponse.failure) {
        $0.phase = .failed
        $0.message = "Check that it's online and connected to the internet."
      }
      backend.discoveryFailure = nil
      backend.streamElsewhere()
      await clock.advance(by: ScreenSharingTransientRetry.delay)
      await store.receive(\.liveStreamFound) {
        $0.phase = .loading
        $0.message = nil
      }
      await store.receive(\.discoveryResponse.success) {
        $0.displays = [self.display]
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
}
