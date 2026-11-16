import CodevisorClient
import CodevisorCore
import ComposableArchitecture
import Foundation
import ScreenSharing
import ScreenSharingConnection
import ScreenSharingV2

@Reducer
public struct ScreenSharingViewer {
  public enum InteractionMode: Hashable, Sendable { case control, view }

  @ObservableState
  public struct State: Equatable {
    public var surface = ScreenSharingSurfaceSnapshot()
    public let machineName: String
    var visible = false
    var dismissedDisplaySwitch: ScreenSharingDisplaySwitch?

    public init(machineName: String) {
      self.machineName = machineName
    }

    public var endpoint: ScreenSharingViewerEndpoint? { surface.endpoint }
    public var displays: [ServerScreenSharingDisplay] { surface.displays }
    public var selectedDisplayId: String? {
      guard let pending = surface.displaySwitch, pending.phase == .switching else { return surface.displayId }

      return pending.displayId
    }

    public var switchesDisplayInSession: Bool { surface.switchesDisplayInSession }

    public var displaySwitchLine: ScreenSharingDisplaySwitchLine? {
      guard isLive, let result = surface.displaySwitch, result != dismissedDisplaySwitch else { return nil }

      let name = surface.displays.first { $0.id == result.displayId }?.name ?? "the other display"
      switch result.phase {
      case .switching: return .switching("Switching to \(name)…")
      case .unavailable(let message): return .failed(message ?? "Couldn't switch to \(name).")
      case .confirmed: return nil
      }
    }
    public var hostNotice: String? { surface.hostNotice }
    public var isLive: Bool { surface.connection == .live }
    public var isReconnecting: Bool { surface.connection == .reconnecting }
    public var interactionMode: InteractionMode { surface.mode }
    public var dynamicResolution: Bool { surface.dynamicResolution }
    public var control: ScreenSharingControlStatus? { surface.control }
    public var hasControl: Bool { surface.hasControl }

    public var canAskForControl: Bool {
      interactionMode == .control && control?.phase == .viewing
    }

    public var failure: String? {
      guard case .failed(let reason) = surface.connection else { return nil }

      return reason.sentence(on: machineName)
    }

    public var failureAction: ScreenSharingFailureAction? {
      guard case .failed(let reason) = surface.connection else { return nil }

      return ScreenSharingFailureAction(for: reason)
    }

    public var stillConnectingStep: String? {
      guard surface.isTakingLong, case .connecting(let stage) = surface.connection else { return nil }

      return stage.step(on: machineName)
    }

    public var preview: ScreenSharingPreview {
      switch surface.connection {
      case .off, .connecting: .connecting
      case .reconnecting: .reconnecting
      case .live: surface.endpoint.map(ScreenSharingPreview.live) ?? .connecting
      case .failed: .failed(failure ?? "", failureAction)
      }
    }
  }

  public enum Action {
    case controlTaken
    case displaySelected(String)
    case displaySwitchDismissed
    case dynamicResolutionToggled
    case hidden
    case interactionModeChanged(InteractionMode)
    case retryButtonTapped
    case shown
    case surfaceChanged(ScreenSharingSurfaceSnapshot)
    case systemKeyTapped(ScreenSharingSystemKey)
  }

  @Dependency(ScreenSharingSurfaceClient.self) var surface
  @Dependency(ScreenSharingEndpointClient.self) var endpointClient

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .controlTaken:
        guard state.isLive else { return .none }
        return .run { [surface] _ in await surface.takeControl() }

      case .displaySelected(let id):
        guard state.displays.contains(where: { $0.id == id }) else { return .none }
        state.dismissedDisplaySwitch = nil
        return .run { [surface] _ in await surface.switchDisplay(id) }

      case .displaySwitchDismissed:
        state.dismissedDisplaySwitch = state.surface.displaySwitch
        return .none

      case .dynamicResolutionToggled:
        let enabled = !state.dynamicResolution
        return .run { [surface] _ in await surface.setDynamicResolution(enabled) }

      case .hidden:
        state.visible = false
        return .none

      case .interactionModeChanged(let mode):
        return .run { [surface] _ in await surface.setMode(mode) }

      case .retryButtonTapped:
        return .run { [surface] _ in await surface.retry() }

      case .shown:
        state.visible = true
        return .none

      case .surfaceChanged(let surface):
        if state.isLive, surface.connection != .live { state.dismissedDisplaySwitch = surface.displaySwitch }
        state.surface = surface
        return .none

      case .systemKeyTapped(let key):
        guard state.isLive, let id = state.endpoint?.id else { return .none }
        let takesControl = !state.hasControl
        return .run { [endpointClient, surface] _ in
          await endpointClient.tapSystemKey(id, key)
          if takesControl { await surface.controlForThisSession() }
        }
      }
    }
  }
}
