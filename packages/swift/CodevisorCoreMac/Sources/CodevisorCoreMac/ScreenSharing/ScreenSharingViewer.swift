import CodevisorClient
import CodevisorCore
import CodevisorScreenSharing
import ComposableArchitecture
import Foundation

/// The viewer's control plane: visibility, display choice, presentation
/// preferences, interaction mode and the lifecycle of one connection at a
/// time, with the control lease as a child feature per endpoint. Everything
/// timed or transport-specific lives in the backend; the long-running effects
/// here are the backend's event stream and the endpoint's control-event
/// stream, and cancelling them is how every transition away from a connection
/// happens — hiding the pane, choosing another display, or closing.
@Reducer
public struct ScreenSharingViewer {
  public enum InteractionMode: Hashable, Sendable { case control, view }
  public enum Phase: Equatable, Sendable {
    case connecting, failed, idle, loading, ready, reconnecting, suspended, viewing
  }

  @ObservableState
  public struct State: Equatable {
    public var displays: [ServerScreenSharingDisplay] = []
    /// The live endpoint while connecting, viewing or reconnecting; nil otherwise.
    public var endpoint: ScreenSharingViewerEndpoint?
    public var interactionMode: InteractionMode = .control
    /// The control lease over the live endpoint's channel.
    public var lease: ControlLease.State?
    public var message: String?
    public var phase: Phase = .idle
    public var preferences: ScreenSharingPanePreferences
    /// Incremented for every preference change the user made here (never for
    /// a synced registry update), so the pane persists exactly those.
    public var preferencesRevision = 0
    public var selectedDisplayId: String?
    var visible = false
    var wantsConnection = false

    public init(preferences: ScreenSharingPanePreferences = .init()) { self.preferences = preferences }

    public var showsDisplayPicker: Bool { ![.connecting, .reconnecting, .viewing].contains(phase) }
  }

  public enum Action {
    case connectButtonTapped
    case connectionEvent(ScreenSharingViewerEvent)
    case discoveryResponse(Result<[ServerScreenSharingDisplay], any Error>)
    case displaySelected(String)
    case fitToWindowChanged(Bool)
    case interactionModeChanged(InteractionMode)
    case lease(ControlLease.Action)
    case paneAppeared
    case paneClosed
    case paneDisappeared
    /// A registry update from another client: applied to the live surface without echo.
    case preferencesSynced(ScreenSharingPanePreferences)
    case retryButtonTapped
  }

  enum CancelID { case connection, controlEvents }

  @Dependency(ScreenSharingViewerBackend.self) var backend
  @Dependency(ScreenSharingEndpointClient.self) var endpointClient

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .connectButtonTapped:
        guard state.visible, state.selectedDisplayId != nil else { return .none }
        state.preferences.preferredDisplayId = state.selectedDisplayId
        state.preferencesRevision += 1
        state.wantsConnection = true
        return connect(&state)

      case .connectionEvent(.opened(let endpoint)):
        state.endpoint = endpoint
        state.lease = ControlLease.State(endpoint: endpoint.id)
        let id = endpoint.id
        return .merge(
          fitEndpoint(state),
          .run { [endpointClient] send in
            for await event in await endpointClient.controlEvents(id) { await send(.lease(.event(event))) }
          }
          .cancellable(id: CancelID.controlEvents, cancelInFlight: true))

      case .connectionEvent(.ready):
        guard [.connecting, .reconnecting].contains(state.phase), state.lease != nil else { return .none }
        state.phase = .viewing
        state.message = nil
        return state.interactionMode == .control ? .send(.lease(.controlRequested)) : .none

      case .connectionEvent(.reconnecting):
        dropEndpoint(&state)
        state.phase = .reconnecting
        state.message = "Reconnecting to this Mac…"
        return .cancel(id: CancelID.controlEvents)

      case .connectionEvent(.ended(let message)):
        dropEndpoint(&state)
        fail(&state, message)
        return .cancel(id: CancelID.controlEvents)

      case .discoveryResponse(.success(let displays)):
        guard state.visible, state.phase == .loading else { return .none }
        state.displays = displays
        if let preferred = state.preferences.preferredDisplayId {
          state.selectedDisplayId = displays.first(where: { $0.id == preferred })?.id
          guard state.selectedDisplayId != nil else {
            fail(&state, "The selected display is unavailable. Choose another display to connect.")
            return .none
          }
        } else {
          state.selectedDisplayId = displays.first?.id
        }
        guard state.selectedDisplayId != nil else {
          fail(&state, "No displays are available on this Mac.")
          return .none
        }
        state.phase = .ready
        return state.wantsConnection ? connect(&state) : .none

      case .discoveryResponse(.failure(let error)):
        guard state.visible, state.phase == .loading, !isTaskCancellation(error) else { return .none }
        fail(&state, serverErrorMessage(error))
        return .none

      case .displaySelected(let id):
        guard state.displays.contains(where: { $0.id == id }) else { return .none }
        state.preferences.preferredDisplayId = id
        state.selectedDisplayId = id
        state.preferencesRevision += 1
        if state.wantsConnection { return connect(&state) }
        state.message = nil
        state.phase = .ready
        return .none

      case .fitToWindowChanged(let fit):
        state.preferences.fitToWindow = fit
        state.preferencesRevision += 1
        return fitEndpoint(state)

      // Keep the user's choice while connecting; ask the lease only once
      // video is up. The lease itself waits for its channel.
      case .interactionModeChanged(let mode):
        state.interactionMode = mode
        guard state.phase == .viewing, state.lease != nil else { return .none }
        return .send(.lease(mode == .control ? .controlRequested : .controlReleased(reason: nil)))

      case .lease(.delegate(.released)):
        if state.phase == .viewing { state.interactionMode = .view }
        return .none

      case .lease:
        return .none

      case .paneAppeared:
        guard !state.visible else { return .none }
        state.visible = true
        return refresh(&state)

      case .paneClosed:
        state.wantsConnection = false
        state.visible = false
        dropEndpoint(&state)
        state.phase = .suspended
        return .merge(.cancel(id: CancelID.connection), .cancel(id: CancelID.controlEvents))

      case .paneDisappeared:
        guard state.visible else { return .none }
        state.visible = false
        dropEndpoint(&state)
        state.phase = .suspended
        return .merge(.cancel(id: CancelID.connection), .cancel(id: CancelID.controlEvents))

      // Apply a registry update without replacing the live surface or echoing
      // the write. A display change from another client requires a new Connect.
      case .preferencesSynced(let preferences):
        guard state.preferences != preferences else { return .none }
        let displayChanged = state.preferences.preferredDisplayId != preferences.preferredDisplayId
        state.preferences = preferences
        guard displayChanged else { return fitEndpoint(state) }
        state.wantsConnection = false
        return .merge(fitEndpoint(state), refresh(&state))

      case .retryButtonTapped:
        return refresh(&state)
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
    state.lease = nil
  }

  private func fail(_ state: inout State, _ message: String) {
    state.phase = .failed
    state.message = message
  }

  private func fitEndpoint(_ state: State) -> Effect<Action> {
    guard let id = state.endpoint?.id else { return .none }
    let fit = state.preferences.fitToWindow
    return .run { [endpointClient] _ in await endpointClient.setFitToWindow(id, fit) }
  }
}
