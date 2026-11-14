import ScreenSharingV2

struct ScreenSharingConnectionStateMachine: Equatable, Sendable {
  enum Event: Equatable, Sendable {
    case surfacesChanged(attached: Bool, visible: Bool)
    case openRequested
    case retryRequested
    case stepEntered(ScreenSharingConnectStage)
    case firstFrameDecoded
    case attemptEnded(ScreenSharingAttemptEnd)
    case stayedLive
    case unseenBrieflyElapsed
    case lingerElapsed
    case machineCameOnline
    case workspaceAppeared
    case systemWoke
    case ended
  }

  enum Unseen: Equatable, Sendable {
    case briefly
    case lingering
  }

  enum Command: Equatable, Sendable {
    case start(ScreenSharingStartIntent, after: Duration, asksWhyItEnded: Bool)
    case stop

    var opens: Bool {
      if case .start(.open, _, _) = self { true } else { false }
    }
  }

  private(set) var state: ScreenSharingConnectionState = .off
  private(set) var unseen: Unseen?
  private(set) var isEnded = false
  private var attached = false
  private var visible = false
  private var triesUsed = 0
  private var retriedHostFailure = false
  private var openPending = false
  private var attemptIntent = ScreenSharingStartIntent.attach

  init() {}

  mutating func handle(_ event: Event, openPending: Bool = false) -> Command? {
    guard !isEnded else { return nil }

    self.openPending = openPending
    switch event {
    case .surfacesChanged(let attached, let visible): return surfacesChanged(attached: attached, visible: visible)
    case .openRequested: return userAsked()
    case .retryRequested: return attached ? userAsked() : nil
    case .stepEntered(let stage): return enter(stage)
    case .firstFrameDecoded: return goLive()
    case .attemptEnded(let end): return attemptEnded(end)
    case .stayedLive: return forgive()
    case .unseenBrieflyElapsed: return unseenBrieflyElapsed()
    case .lingerElapsed: return unseen == .lingering ? turnOff() : nil
    case .machineCameOnline: return recover(from: .cantReach)
    case .workspaceAppeared: return recover(from: .noWorkspace)
    case .systemWoke: return state == .live ? attemptEnded(.dropped(.cantReach)) : nil
    case .ended: return end()
    }
  }

  private mutating func surfacesChanged(attached: Bool, visible: Bool) -> Command? {
    self.attached = attached
    self.visible = visible
    guard visible else {
      if state != .off, unseen == nil { unseen = .briefly }
      return nil
    }

    unseen = nil
    return state == .off ? connect(open: openPending) : nil
  }

  private mutating func unseenBrieflyElapsed() -> Command? {
    guard unseen == .briefly else { return nil }
    guard keepsGoingUnseen else { return turnOff() }

    unseen = .lingering
    return nil
  }

  private var keepsGoingUnseen: Bool {
    switch state {
    case .live: true
    case .reconnecting: attached
    case .off, .connecting, .failed: false
    }
  }

  private mutating func userAsked() -> Command? {
    guard case .failed = state else { return nil }

    return connect(open: true)
  }

  private mutating func recover(from reason: ScreenSharingFailureReason) -> Command? {
    guard state == .failed(reason), visible else { return nil }

    return connect(open: false)
  }

  private mutating func enter(_ stage: ScreenSharingConnectStage) -> Command? {
    if case .connecting = state { state = .connecting(stage) }
    return nil
  }

  private mutating func goLive() -> Command? {
    switch state {
    case .connecting, .reconnecting: state = .live
    case .off, .live, .failed: break
    }
    return nil
  }

  private mutating func forgive() -> Command? {
    guard state == .live else { return nil }

    triesUsed = 0
    retriedHostFailure = false
    return nil
  }

  private mutating func attemptEnded(_ end: ScreenSharingAttemptEnd) -> Command? {
    guard attached || unseen == .briefly else { return turnOff() }

    switch (state, end) {
    case (.off, _), (.failed, _):
      return nil
    case (_, .hostFailed(let message)):
      return hostFailed(message)
    case (.live, .refused(let reason)), (.connecting, .dropped(let reason)):
      return fail(reason)
    case (.live, .dropped):
      return reconnect()
    case (.connecting, .refused(let reason)):
      return upgradesToOpen(reason) ? connect(open: true) : fail(reason)
    case (.reconnecting, .refused(let reason)):
      return upgradesToOpen(reason) ? start(after: .zero, open: true) : fail(reason)
    case (.reconnecting, .dropped(let reason)):
      return nextTry(after: reason)
    }
  }

  private mutating func hostFailed(_ message: String?) -> Command? {
    let reason = ScreenSharingFailureReason.unclassified(message: message)
    if case .connecting = state { return fail(reason) }
    guard !retriedHostFailure else { return fail(reason) }

    retriedHostFailure = true
    return state == .live ? reconnect() : nextTry(after: reason)
  }

  private func upgradesToOpen(_ reason: ScreenSharingFailureReason) -> Bool {
    openPending && attemptIntent == .attach && reason.yieldsToAnOpen
  }

  private mutating func connect(open: Bool) -> Command? {
    state = .connecting(.reachingHost)
    return start(after: .zero, open: open)
  }

  private mutating func reconnect() -> Command? {
    state = .reconnecting
    return nextTry(after: nil, asksWhyItEnded: true)
  }

  private mutating func nextTry(
    after reason: ScreenSharingFailureReason?, asksWhyItEnded: Bool = false
  ) -> Command? {
    guard let wait = ScreenSharingRetryPolicy.wait(afterTries: triesUsed) else {
      return fail(reason == .cantReach ? .cantReach : .keptDropping)
    }

    triesUsed += 1
    return start(after: wait, open: openPending, asksWhyItEnded: asksWhyItEnded)
  }

  private mutating func start(after wait: Duration, open: Bool, asksWhyItEnded: Bool = false) -> Command? {
    attemptIntent = open ? .open : .attach
    return .start(attemptIntent, after: wait, asksWhyItEnded: asksWhyItEnded)
  }

  private mutating func fail(_ reason: ScreenSharingFailureReason) -> Command? {
    state = .failed(reason)
    triesUsed = 0
    retriedHostFailure = false
    return .stop
  }

  private mutating func turnOff() -> Command? {
    guard state != .off else { return nil }

    state = .off
    unseen = nil
    triesUsed = 0
    retriedHostFailure = false
    return .stop
  }

  private mutating func end() -> Command? {
    let command = turnOff()
    isEnded = true
    return command
  }
}
