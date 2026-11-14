import CodevisorClient
import CodevisorTestSupport
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

  @Test func aPaneThatFailsAgainWaitsForANewStreamInsteadOfRetryingOnTheSameOne() async {
    await withMainSerialExecutor {
      let registry = ScreenSharingViewerRegistry()
      let window = RegistryPane(registry, role: .window)
      window.show()
      await window.runner.connected.wait()
      window.runner.send(.opened(endpoint()))
      await awaitObserved { window.log.endpoints.count == 1 }
      let clock = Clocks.TestClock()
      let store = unreachableStore(hearing: RegistryPane(registry, role: .watcher).share, clock: clock)
      let failed: (inout ScreenSharingViewer.State) -> Void = {
        $0.phase = .failed
        $0.message = Self.unreachable
      }
      let retrying: (inout ScreenSharingViewer.State) -> Void = {
        $0.phase = .loading
        $0.message = nil
      }
      await store.send(.paneAppeared) {
        $0.visible = true
        $0.phase = .loading
      }
      await store.receive(\.discoveryResponse.failure, assert: failed)
      await clock.advance(by: ScreenSharingTransientRetry.delay)
      await store.receive(\.liveStreamFound, assert: retrying)
      await store.receive(\.discoveryResponse.failure, assert: failed)
      await clock.advance(by: ScreenSharingTransientRetry.delay)

      window.runner.send(.reconnecting)
      window.runner.send(.opened(endpoint()))
      await awaitObserved { window.log.endpoints.count == 2 }
      await clock.advance(by: ScreenSharingTransientRetry.delay)

      await store.receive(\.liveStreamFound, assert: retrying)
      await store.receive(\.discoveryResponse.failure, assert: failed)
      await store.send(.paneClosed) {
        $0.visible = false
        $0.phase = .suspended
      }
      await store.finish()
      await window.leave()
    }
  }

  private static let unreachable = "Check that it's online and connected to the internet."

  private func unreachableStore(
    hearing share: ScreenSharingViewerRegistry.Share, clock: Clocks.TestClock<Duration>
  ) -> TestStoreOf<ScreenSharingViewer> {
    let backend = FakeBackend(displays: [display])
    backend.discoveryFailure = Self.unreachable
    var sharing = backend.value
    sharing.liveStreams = { await share.liveStreams() }
    return TestStore(initialState: ScreenSharingViewer.State()) {
      ScreenSharingViewer()
    } withDependencies: { [sharing] in
      $0[ScreenSharingViewerBackend.self] = sharing
      $0.continuousClock = clock
    }
  }

  private func endpoint() -> ScreenSharingViewerEndpoint {
    ScreenSharingViewerEndpoint(session: FakeMediaSession(), surface: FakeSurface())
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
