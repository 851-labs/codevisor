import ComposableArchitecture
import Foundation
import OSLog
import ScreenSharing

@Reducer
public struct ControlLease {
  public enum Phase: Equatable, Sendable { case controlling, requesting, viewing }

  @ObservableState
  public struct State: Equatable, Identifiable {
    public let id: UUID
    public var available = false
    public let endpoint: ScreenSharingViewerEndpoint.ID
    public var lease: UUID?
    public var message: String?
    public var phase: Phase = .viewing
    public var requestID: UUID?
    public var automaticRetries: [Date] = []
    public var revokeReason: String?
    public var retriedRequest = false
    public var retriesAFirstRefusal = false
    public var unansweredRequests: Set<UUID> = []
    public var wantsControl = false

    public init(endpoint: ScreenSharingViewerEndpoint.ID, id: UUID = UUID()) {
      self.endpoint = endpoint
      self.id = id
    }
  }

  public enum Action {
    case askedAgainAfterRefusal
    case channelSendFailed(reason: String)
    case connectionWentLive
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

  enum CancelID: Hashable { case heartbeat(UUID), requestDeadline(UUID) }

  static let retriesPerMinute = 3
  static let settlingTime: TimeInterval = 4
  static let refusalRetryDelay: Duration = .seconds(1)

  private static let logger = Logger(subsystem: "com.851labs.Codevisor", category: "ScreenSharing")

  @Dependency(\.continuousClock) var clock
  @Dependency(\.date.now) var now
  @Dependency(ScreenSharingEndpointClient.self) var endpoint
  @Dependency(\.uuid) var uuid

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .askedAgainAfterRefusal:
        guard state.phase == .requesting, state.requestID == nil, state.available else { return .none }
        return request(&state, isRetry: false)

      case .connectionWentLive:
        state.retriesAFirstRefusal = true
        return .none

      case .channelSendFailed(let reason):
        note("could not send: \(reason)", state)
        return pause(&state)

      case .controlReleased(let reason):
        return release(&state, reason: reason)

      case .controlRequested:
        guard state.phase == .viewing else { return .none }
        state.wantsControl = true
        return state.available ? request(&state, isRetry: false) : .none

      case .delegate:
        return .none

      case .event(.availability(let available)):
        guard available != state.available else { return .none }
        state.available = available
        if !available {
          note("channel closed while \(state.phase)", state)
          let effect = pause(&state)
          state.unansweredRequests = []
          return effect
        }
        state.message = nil
        return state.wantsControl && state.phase == .viewing ? request(&state, isRetry: false) : .none

      case .event(.inputLost(let reason)):
        note("input lost while \(state.phase): \(reason ?? "no reason")", state)
        return release(&state, reason: reason)

      case .event(.inputNotice(let notice)):
        guard state.phase == .controlling else { return .none }
        state.message = notice
        return .none

      case .event(.message(.grant(let request, let lease))):
        return granted(request, lease: lease, &state)

      case .event(.message(.denied(let request, let reason))):
        guard state.requestID == request else {
          state.unansweredRequests.remove(request)
          return .none
        }
        note("request \(Self.short(request)) refused: \(reason)", state)
        state.requestID = nil
        guard state.retriesAFirstRefusal, state.wantsControl, state.available else {
          return release(&state, reason: state.revokeReason ?? reason)
        }
        return askAgainSoon(&state)

      case .event(.message(.revoked(let lease, let reason))):
        guard state.lease == lease else { return .none }
        note("lease \(Self.short(lease)) revoked: \(reason)", state)
        return mayAskAgain(state) ? askAgain(&state, after: reason) : release(&state, reason: reason)

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
        guard state.retriedRequest else {
          note("request \(Self.short(state.requestID)) had no answer in 3 s; asking again", state)
          return request(&state, isRetry: true)
        }
        note("request \(Self.short(state.requestID)) had no answer in 3 s either; giving up", state)
        return release(&state, reason: state.revokeReason ?? "The host did not grant control. Try again.")

      case .suspended:
        let effect = pause(&state)
        state.wantsControl = false
        return effect
      }
    }
  }

  private func request(_ state: inout State, isRetry: Bool) -> Effect<Action> {
    setAside(&state)
    let requestID = uuid()
    state.requestID = requestID
    state.retriedRequest = isRetry
    state.phase = .requesting
    state.message = nil
    note("request \(Self.short(requestID)) sent", state)
    let id = state.endpoint
    return .merge(
      .run { [endpoint] send in
        if !(await endpoint.sendControl(id, .request(id: requestID))) {
          await send(.channelSendFailed(reason: "The control channel is unavailable."))
        }
      },
      .run { [clock] send in
        try await clock.sleep(for: .seconds(3))
        await send(.requestTimedOut)
      }
      .cancellable(id: CancelID.requestDeadline(state.id), cancelInFlight: true))
  }

  private func granted(_ request: UUID, lease: UUID, _ state: inout State) -> Effect<Action> {
    guard sent(request, state) else {
      note("grant for request \(Self.short(request)) is another pane's; left alone", state)
      return .none
    }

    state.unansweredRequests.remove(request)
    guard state.phase == .requesting, state.available else {
      note("grant for request \(Self.short(request)) given back: no longer waiting", state)
      let id = state.endpoint
      return .run { [endpoint] _ in _ = await endpoint.sendControl(id, .release(lease: lease)) }
    }

    if let later = state.requestID, later != request { state.unansweredRequests.insert(later) }
    state.requestID = nil
    state.retriedRequest = false
    state.retriesAFirstRefusal = false
    state.revokeReason = nil
    state.lease = lease
    state.phase = .controlling
    state.message = nil
    note("request \(Self.short(request)) granted, lease \(Self.short(lease))", state)
    let id = state.endpoint
    let pane = Self.short(state.id)
    return .merge(
      .cancel(id: CancelID.requestDeadline(state.id)),
      .run { [endpoint] send in
        if let failure = await endpoint.beginInput(id, lease) { await send(.event(.inputLost(failure))) }
      },
      .run { [clock] send in
        var isFirst = true
        for await _ in clock.timer(interval: .seconds(1)) {
          if isFirst { Self.logger.notice("Control \(pane, privacy: .public): first heartbeat") }
          isFirst = false
          await send(.heartbeatTick)
        }
      }
      .cancellable(id: CancelID.heartbeat(state.id), cancelInFlight: true))
  }

  private func mayAskAgain(_ state: State) -> Bool {
    let recent = state.automaticRetries.filter { now.timeIntervalSince($0) < 60 }
    guard state.available, recent.count < Self.retriesPerMinute else { return false }
    guard let last = recent.last else { return true }

    return now.timeIntervalSince(last) >= Self.settlingTime
  }

  private func askAgain(_ state: inout State, after reason: String) -> Effect<Action> {
    note("asking for control again after the host took it back", state)
    state.automaticRetries = state.automaticRetries.filter { now.timeIntervalSince($0) < 60 } + [now]
    state.lease = nil
    state.phase = .viewing
    let id = state.endpoint
    let effect = Effect<Action>.merge(
      .cancel(id: CancelID.heartbeat(state.id)),
      .run { [endpoint] _ in await endpoint.endInput(id) },
      request(&state, isRetry: false))
    state.revokeReason = reason
    return effect
  }

  private func askAgainSoon(_ state: inout State) -> Effect<Action> {
    note("the host was not ready for control yet; asking again in a second", state)
    state.retriesAFirstRefusal = false
    return .run { [clock] send in
      try await clock.sleep(for: Self.refusalRetryDelay)
      await send(.askedAgainAfterRefusal)
    }
    .cancellable(id: CancelID.requestDeadline(state.id), cancelInFlight: true)
  }

  private func sent(_ request: UUID, _ state: State) -> Bool {
    state.requestID == request || state.unansweredRequests.contains(request)
  }

  private func setAside(_ state: inout State) {
    if let request = state.requestID { state.unansweredRequests.insert(request) }
    state.requestID = nil
    state.retriedRequest = false
  }

  private func pause(_ state: inout State) -> Effect<Action> {
    let lease = state.lease
    if state.phase != .viewing { note("paused while \(state.phase)", state) }
    state.revokeReason = nil
    state.wantsControl = state.wantsControl || state.phase != .viewing
    setAside(&state)
    state.lease = nil
    state.phase = .viewing
    let id = state.endpoint
    return .merge(
      .cancel(id: CancelID.requestDeadline(state.id)),
      .cancel(id: CancelID.heartbeat(state.id)),
      .run { [endpoint] _ in
        await endpoint.endInput(id)
        if let lease { _ = await endpoint.sendControl(id, .release(lease: lease)) }
      })
  }

  private func release(_ state: inout State, reason: String?) -> Effect<Action> {
    let wasHeld = state.phase != .viewing
    let lease = state.lease
    if wasHeld { note("given up while \(state.phase)", state) }
    state.wantsControl = false
    setAside(&state)
    state.lease = nil
    state.phase = .viewing
    state.message = reason
    state.revokeReason = nil
    let id = state.endpoint
    return .merge(
      .cancel(id: CancelID.requestDeadline(state.id)),
      .cancel(id: CancelID.heartbeat(state.id)),
      .run { [endpoint] _ in
        await endpoint.endInput(id)
        if let lease { _ = await endpoint.sendControl(id, .release(lease: lease)) }
      },
      wasHeld ? .send(.delegate(.released)) : .none)
  }

  private func note(_ event: String, _ state: State) {
    Self.logger.notice("Control \(Self.short(state.id), privacy: .public): \(event, privacy: .public)")
  }

  private static func short(_ id: UUID?) -> String {
    id.map { String($0.uuidString.prefix(4)) } ?? "none"
  }
}
