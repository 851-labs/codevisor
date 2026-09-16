import CodevisorClient
import CodevisorCore
import CodevisorScreenSharing
import ComposableArchitecture
import Foundation

/// The viewer's control plane: visibility, display choice, presentation
/// preferences, interaction mode and the lifecycle of one connection at a
/// time. Everything timed or transport-specific lives in the backend; the one
/// long-running effect here is the backend's event stream, and cancelling it
/// (`CancelID.connection`) is how every transition away from a connection
/// happens — hiding the pane, choosing another display, disconnecting or
/// closing.
@Reducer
public struct ScreenSharingViewer {
  public enum Phase: Equatable, Sendable {
    case idle, loading, ready, connecting, reconnecting, viewing, suspended, failed
  }
  public enum InteractionMode: Hashable, Sendable { case view, control }

  @ObservableState
  public struct State: Equatable {
    public var phase: Phase = .idle
    public var interactionMode: InteractionMode = .control
    public var message: String?
    public var displays: [ServerScreenSharingDisplay] = []
    public var selectedDisplayId: String?
    public var preferences: ScreenSharingPanePreferences
    /// The live endpoint while connecting, viewing or reconnecting; nil otherwise.
    public var endpoint: ScreenSharingViewerEndpoint?
    /// Incremented for every preference change the user made here (never for
    /// an applied registry update), so the pane persists exactly those.
    public var preferencesRevision = 0
    var visible = false
    var wantsConnection = false

    public init(preferences: ScreenSharingPanePreferences = .init()) { self.preferences = preferences }

    public var showsDisplayPicker: Bool { ![.connecting, .reconnecting, .viewing].contains(phase) }
  }

  public enum Action: Equatable, Sendable {
    case setVisible(Bool)
    case refresh
    case selectDisplay(String)
    case setFitToWindow(Bool)
    case setInteractionMode(InteractionMode)
    /// A registry update from another client: applied to the live surface without echo.
    case applyPreferences(ScreenSharingPanePreferences)
    case connect
    case disconnect
    case close
    case discovered([ServerScreenSharingDisplay])
    case discoveryFailed(String)
    case backend(ScreenSharingViewerEvent)
  }

  enum CancelID { case connection }

  @Dependency(\.screenSharingViewerBackend) var backend

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .setVisible(let visible):
        guard state.visible != visible else { return .none }
        state.visible = visible
        if visible { return refresh(&state) }
        state.endpoint = nil
        state.phase = .suspended
        return .cancel(id: CancelID.connection)

      case .refresh:
        return refresh(&state)

      case .discovered(let displays):
        guard state.visible, state.phase == .loading else { return .none }
        state.displays = displays
        if let preferred = state.preferences.preferredDisplayId {
          state.selectedDisplayId = displays.first(where: { $0.id == preferred })?.id
          guard state.selectedDisplayId != nil else {
            return fail(&state, "The selected display is unavailable. Choose another display to connect.")
          }
        } else {
          state.selectedDisplayId = displays.first?.id
        }
        guard state.selectedDisplayId != nil else { return fail(&state, "No displays are available on this Mac.") }
        state.phase = .ready
        return state.wantsConnection ? connect(&state) : .none

      case .discoveryFailed(let message):
        guard state.visible, state.phase == .loading else { return .none }
        return fail(&state, message)

      case .selectDisplay(let id):
        guard state.displays.contains(where: { $0.id == id }) else { return .none }
        state.preferences.preferredDisplayId = id
        state.selectedDisplayId = id
        state.preferencesRevision += 1
        if state.wantsConnection { return connect(&state) }
        state.message = nil
        state.phase = .ready
        return .none

      case .setFitToWindow(let fit):
        state.preferences.fitToWindow = fit
        state.preferencesRevision += 1
        fitEndpoint(state)
        return .none

      // Keep the user's choice while connecting; send the request only after
      // video and the control channel are ready.
      case .setInteractionMode(let mode):
        state.interactionMode = mode
        guard state.phase == .viewing, let endpoint = state.endpoint else { return .none }
        onMain { if mode == .control { endpoint.control.requestWhenAvailable() } else { endpoint.control.release() } }
        return .none

      // Apply a registry update without replacing the live surface or echoing
      // the write. A display change from another client requires a new Connect.
      case .applyPreferences(let preferences):
        guard state.preferences != preferences else { return .none }
        let displayChanged = state.preferences.preferredDisplayId != preferences.preferredDisplayId
        state.preferences = preferences
        fitEndpoint(state)
        guard displayChanged else { return .none }
        state.wantsConnection = false
        return refresh(&state)

      case .connect:
        guard state.visible, state.selectedDisplayId != nil else { return .none }
        state.preferences.preferredDisplayId = state.selectedDisplayId
        state.preferencesRevision += 1
        state.wantsConnection = true
        return connect(&state)

      case .disconnect:
        state.wantsConnection = false
        state.endpoint = nil
        state.phase = state.visible ? .ready : .suspended
        state.message = nil
        return .cancel(id: CancelID.connection)

      case .close:
        state.wantsConnection = false
        state.visible = false
        state.endpoint = nil
        state.phase = .suspended
        return .cancel(id: CancelID.connection)

      case .backend(.opened(let endpoint)):
        state.endpoint = endpoint
        fitEndpoint(state)
        return .none

      case .backend(.ready):
        guard [.connecting, .reconnecting].contains(state.phase), let endpoint = state.endpoint else { return .none }
        state.phase = .viewing
        state.message = nil
        if state.interactionMode == .control { onMain { endpoint.control.requestWhenAvailable() } }
        return .none

      case .backend(.reconnecting):
        state.endpoint = nil
        state.phase = .reconnecting
        state.message = "Reconnecting to this Mac…"
        return .none

      case .backend(.controlReleased):
        guard state.phase == .viewing else { return .none }
        state.interactionMode = .view
        return .none

      case .backend(.ended(let message)):
        state.endpoint = nil
        return fail(&state, message)
      }
    }
  }

  private func refresh(_ state: inout State) -> Effect<Action> {
    guard state.visible else { return .none }
    state.endpoint = nil
    state.phase = .loading
    state.message = nil
    return .run { [backend] send in
      do {
        try await send(.discovered(backend.discover()))
      } catch {
        guard !isTaskCancellation(error) else { return }
        await send(.discoveryFailed(serverErrorMessage(error)))
      }
    }
    .cancellable(id: CancelID.connection, cancelInFlight: true)
  }

  private func connect(_ state: inout State) -> Effect<Action> {
    guard let display = state.selectedDisplayId else { return .none }
    state.endpoint = nil
    state.phase = .connecting
    state.message = nil
    return .run { [backend] send in
      for await event in await backend.connect(display) { await send(.backend(event)) }
    }
    .cancellable(id: CancelID.connection, cancelInFlight: true)
  }

  private func fail(_ state: inout State, _ message: String) -> Effect<Action> {
    state.phase = .failed
    state.message = message
    return .none
  }

  private func fitEndpoint(_ state: State) {
    guard let endpoint = state.endpoint else { return }
    let fit = state.preferences.fitToWindow
    onMain { endpoint.fit(fit) }
  }

  /// The store runs reducers on the main actor; the endpoint is a main-actor
  /// handle held in state, and driving it synchronously here keeps every
  /// endpoint side effect ordered with the state change that caused it.
  private func onMain(_ work: @MainActor () -> Void) { MainActor.assumeIsolated(work) }
}
