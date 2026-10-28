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

  @Test func aMirrorWhoseStreamEndsWithoutAReasonReconnects() async {
    await withMainSerialExecutor {
      let backend = FakeBackend(displays: [display])
      let clock = Clocks.TestClock()
      let store = await viewer.makeConnectingStore(backend, FakeEndpointClient(), clock: clock)
      let endpoint = backend.open()
      await store.receive(\.connectionEvent.opened) {
        $0.endpoint = endpoint
        $0.lease = ControlLease.State(endpoint: endpoint.id)
      }
      backend.emit(.elsewhere(endpoint))
      await store.receive(\.connectionEvent.elsewhere) {
        $0.endpoint = nil
        $0.lease = nil
        $0.phase = .elsewhere
        $0.mirror = endpoint
      }
      backend.end()
      await clock.advance(by: ScreenSharingTransientRetry.delay)
      await store.receive(\.connectionFinished) {
        $0.mirror = nil
        $0.phase = .loading
      }
      await store.receive(\.discoveryResponse.success) { $0.phase = .connecting }
      expectNoDifference(backend.connections, ["display", "display"])
      await store.send(.paneClosed) {
        $0.visible = false
        $0.phase = .suspended
      }
      await store.finish()
    }
  }
}
