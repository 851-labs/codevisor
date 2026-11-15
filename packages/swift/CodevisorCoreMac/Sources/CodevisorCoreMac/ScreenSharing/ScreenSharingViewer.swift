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

    public init(machineName: String) {
      self.machineName = machineName
    }

    public var endpoint: ScreenSharingViewerEndpoint? { surface.endpoint }
    public var displays: [ServerScreenSharingDisplay] { surface.displays }
    public var selectedDisplayId: String? { surface.displayId }
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

    public var stillConnectingStep: String? {
      guard surface.isTakingLong, case .connecting(let stage) = surface.connection else { return nil }

      return stage.step(on: machineName)
    }

    public var preview: ScreenSharingPreview {
      switch surface.connection {
      case .off, .connecting: .connecting
      case .reconnecting: .reconnecting
      case .live: surface.endpoint.map(ScreenSharingPreview.live) ?? .connecting
      case .failed: .failed(failure ?? "")
      }
    }
  }

  public enum Action {
    case controlTaken
    case displaySelected(String)
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
        return .run { [surface] _ in await surface.switchDisplay(id) }

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
        state.surface = surface
        return .none

      case .systemKeyTapped(let key):
        guard state.isLive, let id = state.endpoint?.id else { return .none }
        let takesControl = !state.hasControl
        return .run { [endpointClient, surface] _ in
          await endpointClient.tapSystemKey(id, key)
          if takesControl { await surface.setMode(.control) }
        }
      }
    }
  }
}
