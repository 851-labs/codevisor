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
      expectNoDifference(asked.value, hasControl ? [] : ["control for this session"])
    }
  }

  private static let studio = ServerScreenSharingDisplay(
    id: "studio", name: "Studio Display", width: 5120, height: 2880)

  private static func live(switch result: ScreenSharingDisplaySwitch?) -> ScreenSharingSurfaceSnapshot {
    var live = ScreenSharingSurfaceSnapshot()
    live.connection = .live
    live.displays = [display, studio]
    live.displayId = display.id
    live.displaySwitch = result
    return live
  }

  @Test func thePickerIsOfferedWhenAnotherDisplayCanOnlyBeExplained() {
    var state = ScreenSharingViewer.State(machineName: "workstation")
    state.surface.displays = [Self.display]
    #expect(!state.offersAChoiceOfDisplays)

    state.surface.unavailableDisplays = [
      ServerScreenSharingUnavailableDisplay(
        id: "vnc:desktop", name: "Desktop", problem: "The desktop on this machine isn't running.")
    ]
    #expect(state.offersAChoiceOfDisplays)
    #expect(state.displays == [Self.display])
  }

  @Test func aFailedSwitchNamesThePickedDisplayEvenOnceItIsNoLongerListed() {
    var state = ScreenSharingViewer.State(machineName: "workstation")
    state.surface = Self.live(
      switch: ScreenSharingDisplaySwitch(displayId: "vnc:screen", name: "Screen", phase: .unavailable(message: nil)))

    #expect(state.displaySwitchLine == .failed("Couldn't switch to Screen."))
  }

  @Test func thePickerShowsADisplayBeingSwitchedToAndGoesBackWhenTheSwitchFails() {
    var state = ScreenSharingViewer.State(machineName: "croissant")
    state.surface = Self.live(switch: ScreenSharingDisplaySwitch(displayId: "studio", phase: .switching))
    #expect(state.selectedDisplayId == "studio")
    #expect(state.displaySwitchLine == .switching("Switching to Studio Display…"))

    state.surface.displaySwitch = ScreenSharingDisplaySwitch(displayId: "studio", phase: .unavailable(message: nil))
    #expect(state.selectedDisplayId == "main")
    #expect(state.displaySwitchLine == .failed("Couldn't switch to Studio Display."))

    state.surface.displaySwitch = ScreenSharingDisplaySwitch(
      displayId: "studio", phase: .unavailable(message: "That display is asleep."))
    #expect(state.displaySwitchLine == .failed("That display is asleep."), "the host's own words win")

    state.surface.displaySwitch = ScreenSharingDisplaySwitch(displayId: "studio", phase: .confirmed)
    state.surface.displayId = "studio"
    #expect(state.selectedDisplayId == "studio" && state.displaySwitchLine == nil)
  }

  @Test func aFailedSwitchStaysUntilItIsDismissedTheUserPicksAgainOrTheSessionLeavesLive() async {
    await withMainSerialExecutor {
      let asked = LockIsolated<[String]>([])
      let store = makeStore(asked)
      store.exhaustivity = .off
      let failed = ScreenSharingDisplaySwitch(displayId: "studio", phase: .unavailable(message: nil))
      await store.send(.surfaceChanged(Self.live(switch: failed)))
      #expect(store.state.displaySwitchLine == .failed("Couldn't switch to Studio Display."))

      await store.send(.displaySwitchDismissed)
      #expect(store.state.displaySwitchLine == nil)
      await store.send(.displaySelected("studio"))
      await store.send(.surfaceChanged(Self.live(switch: failed)))
      #expect(store.state.displaySwitchLine != nil, "a new pick shows its own result, even the same one")

      var reconnecting = Self.live(switch: failed)
      reconnecting.connection = .reconnecting
      await store.send(.surfaceChanged(reconnecting))
      await store.send(.surfaceChanged(Self.live(switch: failed)))
      #expect(store.state.displaySwitchLine == nil, "leaving Live puts the line away for good")
      await store.finish()

      expectNoDifference(asked.value, ["display studio"])
    }
  }

  @Test func aCardKeepsItsShapeWhenItsMachineHasNoPictureToGiveAnyMore() async {
    await withMainSerialExecutor {
      let store = makeStore(LockIsolated([]))
      store.exhaustivity = .off
      var live = ScreenSharingSurfaceSnapshot()
      live.connection = .live
      live.pictureSize = CGSize(width: 3024, height: 1964)
      await store.send(.surfaceChanged(live))
      #expect(store.state.previewShape.picture == 3024.0 / 1964)

      var gone = ScreenSharingSurfaceSnapshot()
      gone.connection = .failed(.cantReach)
      await store.send(.surfaceChanged(gone))
      #expect(store.state.previewShape.picture == 3024.0 / 1964, "the failed card is not reshaped")
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
        controlForThisSession: { asked.withValue { $0.append("control for this session") } },
        setDynamicResolution: { enabled in asked.withValue { $0.append("dynamic resolution \(enabled)") } },
        switchDisplay: { display in asked.withValue { $0.append("display \(display)") } })
      $0[ScreenSharingEndpointClient.self] = endpoints
    }
  }
}
