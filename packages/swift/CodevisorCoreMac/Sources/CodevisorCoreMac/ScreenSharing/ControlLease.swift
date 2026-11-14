import ScreenSharing
import ComposableArchitecture
import Foundation

@Reducer
public struct ControlLease {
  public enum Phase: Equatable, Sendable { case controlling, requesting, viewing }

  @ObservableState
  public struct State: Equatable {
    public var available = false
    public let endpoint: ScreenSharingViewerEndpoint.ID
    public var lease: UUID?
    public var message: String?
    public var phase: Phase = .viewing
    public var requestID: UUID?
    public var unansweredRequestID: UUID?
    public var wantsControl = false

    public init(endpoint: ScreenSharingViewerEndpoint.ID) { self.endpoint = endpoint }
  }

  public enum Action {
    case channelSendFailed(reason: String)
    case controlReleased(reason: String?)
    case controlRequested
    case delegate(Delegate)
    case event(ScreenSharingControlEvent)
    case heartbeatTick
    case requestTimedOut
    case suspended

    @CasePathable
    public enum Delegate: Equatable {
      case released
    }
  }

  enum CancelID { case heartbeat, requestDeadline }

  @Dependency(\.continuousClock) var clock
  @Dependency(ScreenSharingEndpointClient.self) var endpoint
  @Dependency(\.uuid) var uuid

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .channelSendFailed:
        return pause(&state)

      case .controlReleased(let reason):
        let unanswered = requestInFlight(state)
        let effect = release(&state, reason: reason)
        state.unansweredRequestID = unanswered ?? state.unansweredRequestID
        return effect

      case .controlRequested:
        guard state.phase == .viewing else { return .none }
        state.wantsControl = true
        return state.available ? request(&state) : .none

      case .delegate:
        return .none

      case .event(.availability(let available)):
        guard available != state.available else { return .none }
        state.available = available
        if !available {
          state.unansweredRequestID = nil
          return pause(&state)
        }
        state.message = nil
        return state.wantsControl && state.phase == .viewing ? request(&state) : .none

      case .event(.inputLost(let reason)):
        return release(&state, reason: reason)

      case .event(.inputNotice(let notice)):
        guard state.phase == .controlling else { return .none }
        state.message = notice
        return .none

      case .event(.message(.grant(let request, let lease))):
        guard state.requestID == request, state.phase == .requesting, state.available else {
          forget(request, &state)
          let id = state.endpoint
          return .run { [endpoint] _ in _ = await endpoint.sendControl(id, .release(lease: lease)) }
        }
        state.requestID = nil
        state.lease = lease
        state.phase = .controlling
        state.message = nil
        let id = state.endpoint
        return .merge(
          .cancel(id: CancelID.requestDeadline),
          .run { [endpoint] send in
            if let failure = await endpoint.beginInput(id, lease) { await send(.event(.inputLost(failure))) }
          },
          .run { [clock] send in
            for await _ in clock.timer(interval: .seconds(1)) { await send(.heartbeatTick) }
          }
          .cancellable(id: CancelID.heartbeat, cancelInFlight: true))

      case .event(.message(.denied(let request, let reason))):
        guard state.requestID == request else {
          forget(request, &state)
          return .none
        }
        return release(&state, reason: reason)

      case .event(.message(.revoked(let lease, let reason))):
        guard state.lease == lease else { return .none }
        return release(&state, reason: reason)

      case .event(.message):
        return .none

      case .event(.sessionFailed(let reason)):
        return release(&state, reason: reason)

      case .heartbeatTick:
        guard let lease = state.lease else { return .none }
        let id = state.endpoint
        return .run { [endpoint] send in
          if !(await endpoint.sendControl(id, .heartbeat(lease: lease))) {
            await send(.channelSendFailed(reason: "The control channel closed."))
          }
        }

      case .requestTimedOut:
        guard state.phase == .requesting else { return .none }
        return release(&state, reason: "The host did not grant control. Try again.")

      case .suspended:
        let unanswered = requestInFlight(state)
        let effect = pause(&state)
        state.wantsControl = false
        state.unansweredRequestID = unanswered ?? state.unansweredRequestID
        return effect
      }
    }
  }

  private func request(_ state: inout State) -> Effect<Action> {
    let unanswered = state.unansweredRequestID
    let requestID = unanswered ?? uuid()
    state.unansweredRequestID = nil
    state.requestID = requestID
    state.phase = .requesting
    state.message = nil
    let id = state.endpoint
    let deadline = Effect<Action>.run { [clock] send in
      try await clock.sleep(for: .seconds(3))
      await send(.requestTimedOut)
    }
    .cancellable(id: CancelID.requestDeadline, cancelInFlight: true)
    guard unanswered == nil else { return deadline }

    return .merge(
      .run { [endpoint] send in
        if !(await endpoint.sendControl(id, .request(id: requestID))) {
          await send(.channelSendFailed(reason: "The control channel is unavailable."))
        }
      },
      deadline)
  }

  private func requestInFlight(_ state: State) -> UUID? {
    state.phase == .requesting ? state.requestID : nil
  }

  private func forget(_ request: UUID, _ state: inout State) {
    if state.unansweredRequestID == request { state.unansweredRequestID = nil }
  }

  private func pause(_ state: inout State) -> Effect<Action> {
    let lease = state.lease
    state.wantsControl = state.wantsControl || state.phase != .viewing
    state.requestID = nil
    state.lease = nil
    state.phase = .viewing
    let id = state.endpoint
    return .merge(
      .cancel(id: CancelID.requestDeadline),
      .cancel(id: CancelID.heartbeat),
      .run { [endpoint] _ in
        await endpoint.endInput(id)
        if let lease { _ = await endpoint.sendControl(id, .release(lease: lease)) }
      })
  }

  private func release(_ state: inout State, reason: String?) -> Effect<Action> {
    let wasHeld = state.phase != .viewing
    let lease = state.lease
    state.wantsControl = false
    state.requestID = nil
    state.lease = nil
    state.phase = .viewing
    state.message = reason
    let id = state.endpoint
    return .merge(
      .cancel(id: CancelID.requestDeadline),
      .cancel(id: CancelID.heartbeat),
      .run { [endpoint] _ in
        await endpoint.endInput(id)
        if let lease { _ = await endpoint.sendControl(id, .release(lease: lease)) }
      },
      wasHeld ? .send(.delegate(.released)) : .none)
  }
}
