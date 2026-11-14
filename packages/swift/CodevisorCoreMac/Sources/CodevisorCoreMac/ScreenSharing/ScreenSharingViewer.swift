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
    public var interactionMode: InteractionMode = .control
    public var lease: ControlLease.State?
    public var preferences: ScreenSharingPanePreferences
    public var preferencesRevision = 0
    public var dynamicResolution: Bool
    public var dynamicResolutionRevision = 0
    public let machineName: String
    var visible = false

    public init(
      machineName: String, preferences: ScreenSharingPanePreferences = .init(), dynamicResolution: Bool = false
    ) {
      self.machineName = machineName
      self.preferences = preferences
      self.dynamicResolution = dynamicResolution
    }

    public var endpoint: ScreenSharingViewerEndpoint? { surface.endpoint }
    public var mirror: ScreenSharingViewerEndpoint? { surface.mirror }
    public var displays: [ServerScreenSharingDisplay] { surface.displays }
    public var selectedDisplayId: String? { surface.displayId ?? preferences.preferredDisplayId }
    public var hostNotice: String? { surface.hostNotice }
    public var isLive: Bool { surface.connection == .live }
    public var isReconnecting: Bool { surface.connection == .reconnecting }

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
      case .live: (surface.mirror ?? surface.endpoint).map(ScreenSharingPreview.live) ?? .connecting
      case .failed: .failed(failure ?? "")
      }
    }
  }

  public enum Action {
    case displaySelected(String)
    case dynamicResolutionToggled
    case hidden
    case interactionModeChanged(InteractionMode)
    case lease(ControlLease.Action)
    case preferencesSynced(ScreenSharingPanePreferences)
    case retryButtonTapped
    case showHereTapped
    case shown
    case surfaceChanged(ScreenSharingSurfaceSnapshot)
    case systemKeyTapped(ScreenSharingSystemKey)
  }

  enum CancelID { case controlEvents }

  @Dependency(ScreenSharingSurfaceClient.self) var surface
  @Dependency(ScreenSharingEndpointClient.self) var endpointClient

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .displaySelected(let id):
        guard state.displays.contains(where: { $0.id == id }) else { return .none }
        if state.preferences.preferredDisplayId != id {
          state.preferences.preferredDisplayId = id
          state.preferencesRevision += 1
        }
        return .run { [surface] _ in await surface.switchDisplay(id) }

      case .dynamicResolutionToggled:
        state.dynamicResolution.toggle()
        state.dynamicResolutionRevision += 1
        guard let id = state.endpoint?.id else { return .none }
        let enabled = state.dynamicResolution
        return .run { [endpointClient] _ in await endpointClient.setDynamicResolution(id, enabled, nil, nil) }

      case .hidden:
        guard state.visible else { return .none }
        state.visible = false
        return state.lease == nil ? .none : .send(.lease(.suspended))

      case .interactionModeChanged(let mode):
        state.interactionMode = mode
        guard state.isLive, state.lease != nil else { return .none }
        return .send(.lease(mode == .control ? .controlRequested : .controlReleased(reason: nil)))

      case .lease:
        return .none

      case .preferencesSynced(let preferences):
        guard state.preferences != preferences else { return .none }
        let display = preferences.preferredDisplayId
        let displayChanged = state.preferences.preferredDisplayId != display
        state.preferences = preferences
        guard displayChanged, state.visible, let display else { return .none }
        return .run { [surface] _ in await surface.switchDisplay(display) }

      case .retryButtonTapped:
        return .run { [surface] _ in await surface.retry() }

      case .showHereTapped:
        guard state.mirror != nil else { return .none }
        return .run { [surface] _ in await surface.takePicture() }

      case .shown:
        guard !state.visible else { return .none }
        state.visible = true
        return wantsControl(state) ? .send(.lease(.controlRequested)) : .none

      case .surfaceChanged(let surface):
        return show(surface, &state)

      case .systemKeyTapped(let key):
        guard state.isLive, let id = state.endpoint?.id, let lease = state.lease else { return .none }
        let tap = Effect<Action>.run { [endpointClient] _ in await endpointClient.tapSystemKey(id, key) }
        guard lease.phase == .viewing else { return tap }
        state.interactionMode = .control
        return .merge(tap, .send(.lease(.controlRequested)))
      }
    }
    .ifLet(\.lease, action: \.lease) {
      ControlLease()
    }
  }

  private func wantsControl(_ state: State) -> Bool {
    state.visible && state.isLive && state.lease != nil && state.interactionMode == .control
  }

  private func show(_ surface: ScreenSharingSurfaceSnapshot, _ state: inout State) -> Effect<Action> {
    let previous = state.surface
    state.surface = surface
    let tookThePicture = surface.endpoint != previous.endpoint
    let wentLive = surface.connection == .live && previous.connection != .live
    let picture = tookThePicture ? hold(surface.endpoint, &state) : .none
    guard tookThePicture || wentLive, wantsControl(state) else { return picture }

    return .merge(picture, .send(.lease(.controlRequested)))
  }

  private func hold(_ endpoint: ScreenSharingViewerEndpoint?, _ state: inout State) -> Effect<Action> {
    guard let endpoint else {
      state.lease = nil
      return .cancel(id: CancelID.controlEvents)
    }

    state.lease = ControlLease.State(endpoint: endpoint.id)
    let id = endpoint.id
    let display = state.displays.first { $0.id == state.selectedDisplayId }
    let defaultSize = display?.defaultWidth.flatMap { width in display?.defaultHeight.map { [width, $0] } }
    let dynamicResolution = state.dynamicResolution
    let canScale = display?.scales?.contains(2) == true
    return .merge(
      .run { [endpointClient] _ in
        await endpointClient.setDynamicResolution(id, dynamicResolution, defaultSize, canScale)
      },
      .run { [endpointClient] send in
        for await event in await endpointClient.controlEvents(id) { await send(.lease(.event(event))) }
      }
      .cancellable(id: CancelID.controlEvents, cancelInFlight: true))
  }
}
