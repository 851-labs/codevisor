import CodevisorClient
import CodevisorCore
import ScreenSharing
import ScreenSharingV2
import CodevisorTestSupport
import ComposableArchitecture
import CustomDump
import Foundation
import Testing
@testable import CodevisorCoreMac

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

  @Test func aSlowConnectSaysWhichStepItsOnAndTheErrorReplacesIt() async {
    await withMainSerialExecutor {
      let backend = FakeBackend(displays: [display])
      let discovery = TestSignal()
      backend.discoveryGate = discovery
      let clock = Clocks.TestClock()
      let store = makeStore(backend, clock: clock)
      await store.send(.paneAppeared) {
        $0.visible = true
        $0.phase = .loading
      }
      await clock.advance(by: .seconds(3))
      await clock.advance(by: .seconds(1))
      await store.receive(\.discoveryTakingLong) { $0.connectStep = .reachingHost }
      #expect(store.state.stillConnectingStep(on: "Studio") == "Reaching Studio…")
      discovery.signal()
      await store.receive(\.discoveryResponse.success) {
        $0.displays = [self.display]
        $0.preferences.preferredDisplayId = "display"
        $0.preferencesRevision = 1
        $0.selectedDisplayId = "display"
        $0.phase = .connecting
      }
      backend.emit(.progress(.handshake))
      await store.receive(\.connectionEvent) { $0.connectStep = .handshake }
      #expect(store.state.stillConnectingStep(on: "Studio") == "Setting up video…")
      backend.emit(.ended(ScreenSharingConnectStage.handshake.failure))
      await store.receive(\.connectionEvent) {
        $0.phase = .failed
        $0.message = ScreenSharingConnectStage.handshake.failure
        $0.connectStep = nil
      }
      await store.send(.paneClosed) {
        $0.visible = false
        $0.phase = .suspended
      }
      await store.finish()
    }
  }

  private func makeStore(
    _ backend: FakeBackend, preferences: ScreenSharingPanePreferences = .init(),
    clock: Clocks.TestClock<Duration> = .init()
  ) -> TestStoreOf<ScreenSharingViewer> {
    TestStore(initialState: ScreenSharingViewer.State(preferences: preferences)) {
      ScreenSharingViewer()
    } withDependencies: {
      $0[ScreenSharingViewerBackend.self] = backend.value
      $0[ScreenSharingEndpointClient.self] = FakeEndpointClient().value
      $0.continuousClock = clock
      $0.uuid = .incrementing
    }
  }
}
