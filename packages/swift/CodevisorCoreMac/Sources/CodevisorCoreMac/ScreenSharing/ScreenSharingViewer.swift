import CodevisorClient
import CodevisorCore
import CodevisorScreenSharing
import ComposableArchitecture
import Foundation

/// The viewer's control plane: visibility, display choice, presentation
/// preferences, interaction mode and the lifecycle of one connection at a
/// time, with the control lease as a child feature per endpoint. A visible
/// pane is always connecting or connected: discovery picks the display the
/// pane last used, else the first one, and connects at once; the toolbar's
/// display menu reconnects on choice. Everything
/// timed or transport-specific lives in the backend; the long-running effects
/// here are the backend's event stream and the endpoint's control-event
/// stream, and cancelling them is how every transition away from a connection
/// happens — hiding the pane, choosing another display, or closing.
@Reducer
public struct ScreenSharingViewer {
  public enum InteractionMode: Hashable, Sendable { case control, view }
  public enum Phase: Equatable, Sendable {
    case connecting, failed, idle, loading, reconnecting, suspended, viewing
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

    public init(preferences: ScreenSharingPanePreferences = .init()) { self.preferences = preferences }
  }

  public enum Action {
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
    /// A VNC server entered in the pane: saved with its password, listed and connected.
    case vncTargetSubmitted(ScreenSharingVNCTarget, password: String?)
    /// The saved VNC server forgotten, password included.
    case vncTargetRemoved
  }

  enum CancelID { case connection, controlEvents }

  @Dependency(ScreenSharingViewerBackend.self) var backend
  @Dependency(ScreenSharingEndpointClient.self) var endpointClient
  @Dependency(ScreenSharingVNCCredentials.self) var credentials

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
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

      // The display the pane last used when it is still listed, else the first one.
      case .discoveryResponse(.success(let displays)):
        guard state.visible, state.phase == .loading else { return .none }
        state.displays = Self.listing(displays, vnc: state.preferences.vnc)
        let preferred = state.preferences.preferredDisplayId
        guard let chosen = state.displays.first(where: { $0.id == preferred }) ?? state.displays.first else {
          fail(&state, "No displays are available on this Mac.")
          return .none
        }
        return select(chosen.id, &state)

      // A machine without screen sharing still offers the saved VNC server.
      case .discoveryResponse(.failure(let error)):
        guard state.visible, state.phase == .loading, !isTaskCancellation(error) else { return .none }
        state.displays = Self.listing([], vnc: state.preferences.vnc)
        if let preferred = state.preferences.preferredDisplayId, state.displays.contains(where: { $0.id == preferred })
        {
          return select(preferred, &state)
        }
        fail(&state, serverErrorMessage(error))
        return .none

      case .displaySelected(let id):
        guard state.displays.contains(where: { $0.id == id }) else { return .none }
        return select(id, &state)

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
        return .merge(fitEndpoint(state), refresh(&state))

      case .retryButtonTapped:
        return refresh(&state)

      case .vncTargetSubmitted(let target, let password):
        guard state.visible else { return .none }
        state.preferences.vnc = target
        state.preferences.preferredDisplayId = target.displayId
        state.preferencesRevision += 1
        state.displays = Self.listing(state.displays, vnc: target)
        state.selectedDisplayId = target.displayId
        let account = target.credentialAccount
        // The backend reads the password at connection time: the save must land first.
        return .concatenate(
          .run { [credentials] _ in try? await credentials.save(account, password) },
          connect(&state))

      case .vncTargetRemoved:
        guard let target = state.preferences.vnc else { return .none }
        state.preferences.vnc = nil
        if state.preferences.preferredDisplayId == target.displayId { state.preferences.preferredDisplayId = nil }
        state.preferencesRevision += 1
        let account = target.credentialAccount
        return .merge(
          .run { [credentials] _ in try? await credentials.save(account, nil) },
          refresh(&state))
      }
    }
    .ifLet(\.lease, action: \.lease) {
      ControlLease()
    }
  }

  /// The machine's displays followed by the saved VNC server's single entry
  /// (size unknown until connected, shown without dimensions).
  static func listing(
    _ displays: [ServerScreenSharingDisplay], vnc: ScreenSharingVNCTarget?
  ) -> [ServerScreenSharingDisplay] {
    let machine = displays.filter { ScreenSharingVNCTarget(displayId: $0.id) == nil }
    guard let vnc else { return machine }
    return machine + [ServerScreenSharingDisplay(id: vnc.displayId, name: vnc.displayName, width: 0, height: 0)]
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

  /// Remembers `id` as the pane's display (persisted only when it changed) and connects to it.
  private func select(_ id: String, _ state: inout State) -> Effect<Action> {
    if state.preferences.preferredDisplayId != id {
      state.preferences.preferredDisplayId = id
      state.preferencesRevision += 1
    }
    state.selectedDisplayId = id
    return connect(&state)
  }

  private func connect(_ state: inout State) -> Effect<Action> {
    guard state.visible, let display = state.selectedDisplayId else { return .none }
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
