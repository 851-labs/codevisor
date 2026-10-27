import CodevisorClient
import CodevisorCore
import ScreenSharing
import ComposableArchitecture
import Foundation

@Reducer
public struct ScreenSharingViewer {
  public enum InteractionMode: Hashable, Sendable { case control, view }
  public enum Phase: Equatable, Sendable {
    case connecting, elsewhere, failed, idle, loading, reconnecting, suspended, viewing
  }

  @ObservableState
  public struct State: Equatable {
    public var displays: [ServerScreenSharingDisplay] = []
    public var endpoint: ScreenSharingViewerEndpoint?
    public var mirror: ScreenSharingViewerEndpoint?
    public var interactionMode: InteractionMode = .control
    public var lease: ControlLease.State?
    public var message: String?
    public var hostNotice: String?
    public var phase: Phase = .idle
    public var preferences: ScreenSharingPanePreferences
    public var preferencesRevision = 0
    public var selectedDisplayId: String?
    public var dynamicResolution: Bool
    public var dynamicResolutionRevision = 0
    var visible = false

    public init(preferences: ScreenSharingPanePreferences = .init(), dynamicResolution: Bool = false) {
      self.preferences = preferences
      self.dynamicResolution = dynamicResolution
    }
  }

  public enum Action {
    case connectionEvent(ScreenSharingViewerEvent)
    case discoveryResponse(Result<[ServerScreenSharingDisplay], any Error>)
    case displaySelected(String)
    case dynamicResolutionToggled
    case hiddenGraceExpired
    case interactionModeChanged(InteractionMode)
    case lease(ControlLease.Action)
    case paneAppeared
    case paneClosed
    case paneDisappeared
    case preferencesSynced(ScreenSharingPanePreferences)
    case retryButtonTapped
    case showHereTapped
    case systemKeyTapped(ScreenSharingSystemKey)
  }

  enum CancelID { case connection, controlEvents, hiddenGrace }

  static let hiddenGrace: Duration = .seconds(300)

  @Dependency(ScreenSharingViewerBackend.self) var backend
  @Dependency(\.continuousClock) var clock
  @Dependency(ScreenSharingEndpointClient.self) var endpointClient

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .connectionEvent(.opened(let endpoint)):
        if state.phase == .elsewhere { state.phase = .connecting }
        state.mirror = nil
        state.endpoint = endpoint
        state.lease = ControlLease.State(endpoint: endpoint.id)
        let id = endpoint.id
        let display = state.displays.first(where: { $0.id == state.selectedDisplayId })
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

      case .connectionEvent(.ready):
        guard [.connecting, .reconnecting].contains(state.phase), state.lease != nil else { return .none }
        state.phase = .viewing
        state.message = nil
        state.hostNotice = nil
        return state.visible && state.interactionMode == .control ? .send(.lease(.controlRequested)) : .none

      case .connectionEvent(.reconnecting):
        dropEndpoint(&state)
        state.phase = .reconnecting
        state.message = "Reconnecting to this Mac…"
        return .cancel(id: CancelID.controlEvents)

      case .connectionEvent(.hostNotice(let notice)):
        guard [.connecting, .reconnecting, .viewing].contains(state.phase) else { return .none }
        state.hostNotice = notice
        return .none

      case .connectionEvent(.elsewhere(let mirror)):
        dropEndpoint(&state)
        state.phase = .elsewhere
        state.mirror = mirror
        state.message = nil
        return .cancel(id: CancelID.controlEvents)

      case .connectionEvent(.ended(let message)):
        dropEndpoint(&state)
        fail(&state, message)
        return .cancel(id: CancelID.controlEvents)

      case .discoveryResponse(.success(let displays)):
        guard state.phase == .loading else { return .none }
        state.displays = displays
        let preferred = state.preferences.preferredDisplayId
        guard let chosen = state.displays.first(where: { $0.id == preferred }) ?? state.displays.first else {
          fail(&state, "No displays are available on this Mac.")
          return .none
        }
        return select(chosen.id, &state)

      case .discoveryResponse(.failure(let error)):
        guard state.phase == .loading, !isTaskCancellation(error) else { return .none }
        fail(&state, serverErrorMessage(error))
        return .none

      case .displaySelected(let id):
        guard state.displays.contains(where: { $0.id == id }) else { return .none }
        return select(id, &state)

      case .hiddenGraceExpired:
        guard !state.visible else { return .none }
        return disconnect(&state)

      case .dynamicResolutionToggled:
        state.dynamicResolution.toggle()
        state.dynamicResolutionRevision += 1
        guard let id = state.endpoint?.id else { return .none }
        let enabled = state.dynamicResolution
        return .run { [endpointClient] _ in await endpointClient.setDynamicResolution(id, enabled, nil, nil) }

      case .interactionModeChanged(let mode):
        state.interactionMode = mode
        guard state.phase == .viewing, state.lease != nil else { return .none }
        return .send(.lease(mode == .control ? .controlRequested : .controlReleased(reason: nil)))

      case .systemKeyTapped(let key):
        guard state.phase == .viewing, let id = state.endpoint?.id, let lease = state.lease else { return .none }
        let tap = Effect<Action>.run { [endpointClient] _ in await endpointClient.tapSystemKey(id, key) }
        guard lease.phase == .viewing else { return tap }
        state.interactionMode = .control
        return .merge(tap, .send(.lease(.controlRequested)))

      case .lease:
        return .none

      case .paneAppeared:
        guard !state.visible else { return .none }
        state.visible = true
        let shown = Effect<Action>.run { [backend] _ in await backend.setVisible(true) }
        guard Self.keepsConnection(state.phase) else { return .merge(shown, refresh(&state)) }
        let resume: Effect<Action> =
          state.phase == .viewing && state.interactionMode == .control ? .send(.lease(.controlRequested)) : .none
        return .merge(shown, .cancel(id: CancelID.hiddenGrace), resume)

      case .paneClosed:
        state.visible = false
        return .merge(.run { [backend] _ in await backend.retire() }, disconnect(&state))

      case .paneDisappeared:
        guard state.visible else { return .none }
        state.visible = false
        let hidden = Effect<Action>.run { [backend] _ in await backend.setVisible(false) }
        guard Self.keepsConnection(state.phase) else { return .merge(hidden, disconnect(&state)) }
        return .merge(
          hidden,
          state.lease == nil ? .none : .send(.lease(.suspended)),
          .run { [clock] send in
            try await clock.sleep(for: Self.hiddenGrace)
            await send(.hiddenGraceExpired)
          }
          .cancellable(id: CancelID.hiddenGrace, cancelInFlight: true))

      case .preferencesSynced(let preferences):
        guard state.preferences != preferences else { return .none }
        let displayChanged = state.preferences.preferredDisplayId != preferences.preferredDisplayId
        state.preferences = preferences
        guard displayChanged else { return .none }
        return state.visible ? refresh(&state) : disconnect(&state)

      case .retryButtonTapped:
        return refresh(&state)

      case .showHereTapped:
        guard state.phase == .elsewhere else { return .none }
        return .run { [backend] _ in await backend.claim() }
      }
    }
    .ifLet(\.lease, action: \.lease) {
      ControlLease()
    }
  }

  private func refresh(_ state: inout State) -> Effect<Action> {
    guard state.visible else { return .none }
    dropEndpoint(&state)
    state.phase = .loading
    state.message = nil
    return .merge(
      .cancel(id: CancelID.controlEvents),
      .run { [backend] send in
        await send(.discoveryResponse(Result { try await backend.discover() }))
      }
      .cancellable(id: CancelID.connection, cancelInFlight: true))
  }

  private func select(_ id: String, _ state: inout State) -> Effect<Action> {
    if state.preferences.preferredDisplayId != id {
      state.preferences.preferredDisplayId = id
      state.preferencesRevision += 1
    }
    state.selectedDisplayId = id
    return connect(&state)
  }

  private func disconnect(_ state: inout State) -> Effect<Action> {
    dropEndpoint(&state)
    state.phase = .suspended
    return .merge(
      .cancel(id: CancelID.connection), .cancel(id: CancelID.controlEvents), .cancel(id: CancelID.hiddenGrace))
  }

  static func keepsConnection(_ phase: Phase) -> Bool {
    [.loading, .connecting, .elsewhere, .reconnecting, .viewing].contains(phase)
  }

  private func connect(_ state: inout State) -> Effect<Action> {
    guard let display = state.selectedDisplayId else { return .none }
    dropEndpoint(&state)
    state.phase = .connecting
    state.message = nil
    return .merge(
      .cancel(id: CancelID.controlEvents),
      .run { [backend] send in
        for await event in await backend.connect(display) { await send(.connectionEvent(event)) }
      }
      .cancellable(id: CancelID.connection, cancelInFlight: true))
  }

  private func dropEndpoint(_ state: inout State) {
    state.endpoint = nil
    state.mirror = nil
    state.lease = nil
    state.hostNotice = nil
  }

  private func fail(_ state: inout State, _ message: String) {
    state.phase = .failed
    state.message = message
  }
}
