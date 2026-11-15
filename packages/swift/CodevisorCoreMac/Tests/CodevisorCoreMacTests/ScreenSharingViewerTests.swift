import CodevisorClient
import ComposableArchitecture
import Foundation
import ScreenSharing
import ScreenSharingConnection
import Testing

@testable import CodevisorCoreMac

@MainActor
struct ScreenSharingViewerTests {
  private static let display = ServerScreenSharingDisplay(id: "main", name: "Built-in", width: 3024, height: 1964)

  @Test func aPaneAsksItsMachineForControlModeResolutionAndDisplayInsteadOfKeepingThem() async {
    await withMainSerialExecutor {
      let asked = LockIsolated<[String]>([])
      let store = makeStore(asked)
      await store.send(.controlTaken)
      var live = ScreenSharingSurfaceSnapshot()
      live.connection = .live
      live.displays = [Self.display]
      await store.send(.surfaceChanged(live)) { $0.surface = live }

      await store.send(.controlTaken)
      await store.send(.interactionModeChanged(.view))
      await store.send(.dynamicResolutionToggled)
      await store.send(.displaySelected("main"))
      await store.send(.displaySelected("gone"))
      await store.send(.retryButtonTapped)
      await store.finish()

      expectNoDifference(
        asked.value, ["take control", "mode view", "dynamic resolution true", "display main", "retry"])
    }
  }

  @Test func whatAPaneShowsComesFromItsMachinesConnection() {
    var state = ScreenSharingViewer.State(machineName: "croissant")
    state.surface.mode = .view
    state.surface.dynamicResolution = true
    state.surface.control = ScreenSharingControlStatus(phase: .viewing, message: "Accessibility required")
    #expect(state.interactionMode == .view && state.dynamicResolution && !state.hasControl)
    #expect(!state.canAskForControl, "View-only never offers Request Control")

    state.surface.mode = .control
    #expect(state.canAskForControl)
    state.surface.control = ScreenSharingControlStatus(phase: .controlling)
    #expect(state.hasControl && !state.canAskForControl)
    state.surface.connection = .failed(.noVideo)
    #expect(state.failure == "Connected, but croissant sent no picture.")
  }

  @Test(arguments: [false, true])
  func aSystemKeyIsHandedToTheEndpointAndTakesControlFirstWhenThePaneHasNone(hasControl: Bool) async {
    await withMainSerialExecutor {
      let asked = LockIsolated<[String]>([])
      let client = FakeEndpointClient()
      let store = makeStore(asked, endpoints: client.value)
      await store.send(.systemKeyTapped(.missionControl))
      let endpoint = ScreenSharingViewerEndpoint(session: FakeMediaSession(), surface: FakeSurface())
      defer { endpoint.close() }
      var live = ScreenSharingSurfaceSnapshot()
      live.connection = .live
      live.endpoint = endpoint
      live.control = hasControl ? ScreenSharingControlStatus(phase: .controlling) : nil
      await store.send(.surfaceChanged(live)) { $0.surface = live }

      await store.send(.systemKeyTapped(.missionControl))
      await store.finish()

      expectNoDifference(client.systemKeys.map(\.key), [.missionControl])
      expectNoDifference(asked.value, hasControl ? [] : ["mode control"])
    }
  }

  private func makeStore(
    _ asked: LockIsolated<[String]>, endpoints: ScreenSharingEndpointClient = ScreenSharingEndpointClient()
  ) -> TestStoreOf<ScreenSharingViewer> {
    TestStore(initialState: ScreenSharingViewer.State(machineName: "croissant")) {
      ScreenSharingViewer()
    } withDependencies: {
      $0[ScreenSharingSurfaceClient.self] = ScreenSharingSurfaceClient(
        retry: { asked.withValue { $0.append("retry") } },
        takeControl: { asked.withValue { $0.append("take control") } },
        setMode: { mode in asked.withValue { $0.append("mode \(mode)") } },
        setDynamicResolution: { enabled in asked.withValue { $0.append("dynamic resolution \(enabled)") } },
        switchDisplay: { display in asked.withValue { $0.append("display \(display)") } })
      $0[ScreenSharingEndpointClient.self] = endpoints
    }
  }
}
