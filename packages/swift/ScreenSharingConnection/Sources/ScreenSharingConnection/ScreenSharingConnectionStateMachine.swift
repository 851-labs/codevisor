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
  }

  private(set) var state: ScreenSharingConnectionState = .off
  private(set) var unseen: Unseen?
  private var attached = false
  private var visible = false
  private var triesUsed = 0
  private var wantsOpen = false
  private var attemptIntent = ScreenSharingStartIntent.attach
  private var isEnded = false

  init() {}

  mutating func handle(_ event: Event) -> Command? {
    guard !isEnded else { return nil }

    switch event {
    case .surfacesChanged(let attached, let visible): return surfacesChanged(attached: attached, visible: visible)
    case .openRequested: return openRequested()
    case .retryRequested: return retryRequested()
    case .stepEntered(let stage): return enter(stage)
    case .firstFrameDecoded: return goLive()
    case .attemptEnded(let end): return attemptEnded(end)
    case .stayedLive: return forgetTries()
    case .unseenBrieflyElapsed: return unseenBrieflyElapsed()
    case .lingerElapsed: return unseen == .lingering ? turnOff() : nil
    case .machineCameOnline: return state == .failed(.cantReach) && visible ? connect() : nil
    case .systemWoke: return state == .live ? attemptEnded(.dropped(.cantReach)) : nil
    case .ended: return end()
    }
  }

  private mutating func surfacesChanged(attached: Bool, visible: Bool) -> Command? {
    self.attached = attached
    self.visible = visible
    if !attached { wantsOpen = false }
    guard visible else {
      if state != .off, unseen == nil { unseen = .briefly }
      return nil
    }

    unseen = nil
    return state == .off ? connect() : nil
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

  private mutating func openRequested() -> Command? {
    guard state != .live else { return nil }

    wantsOpen = true
    guard case .failed = state else { return nil }

    return connect()
  }

  private mutating func retryRequested() -> Command? {
    guard case .failed = state, attached else { return nil }

    wantsOpen = true
    return connect()
  }

  private mutating func enter(_ stage: ScreenSharingConnectStage) -> Command? {
    if case .connecting = state { state = .connecting(stage) }
    return nil
  }

  private mutating func goLive() -> Command? {
    guard isAttempting else { return nil }

    state = .live
    wantsOpen = false
    return nil
  }

  private mutating func forgetTries() -> Command? {
    if state == .live { triesUsed = 0 }
    return nil
  }

  private mutating func attemptEnded(_ end: ScreenSharingAttemptEnd) -> Command? {
    guard attached || unseen == .briefly else { return turnOff() }

    switch (state, end) {
    case (.off, _), (.failed, _):
      return nil
    case (.live, .refused(let reason)):
      return fail(reason)
    case (.live, .dropped):
      return reconnect()
    case (.connecting, .refused(let reason)), (.connecting, .dropped(let reason)):
      return upgradesToOpen(reason) ? connect() : fail(reason)
    case (.reconnecting, .refused(let reason)):
      return upgradesToOpen(reason) ? start(after: .zero) : fail(reason)
    case (.reconnecting, .dropped(let reason)):
      return nextTry(after: reason)
    }
  }

  private var isAttempting: Bool {
    switch state {
    case .connecting, .reconnecting: true
    case .off, .live, .failed: false
    }
  }

  private func upgradesToOpen(_ reason: ScreenSharingFailureReason) -> Bool {
    guard case .inUse = reason else { return false }

    return wantsOpen && attemptIntent == .attach
  }

  private mutating func connect() -> Command? {
    state = .connecting(.reachingHost)
    return start(after: .zero)
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
    return start(after: wait, asksWhyItEnded: asksWhyItEnded)
  }

  private mutating func start(after wait: Duration, asksWhyItEnded: Bool = false) -> Command? {
    attemptIntent = wantsOpen ? .open : .attach
    wantsOpen = false
    return .start(attemptIntent, after: wait, asksWhyItEnded: asksWhyItEnded)
  }

  private mutating func fail(_ reason: ScreenSharingFailureReason) -> Command? {
    state = .failed(reason)
    triesUsed = 0
    wantsOpen = false
    return .stop
  }

  private mutating func turnOff() -> Command? {
    guard state != .off else { return nil }

    state = .off
    unseen = nil
    triesUsed = 0
    wantsOpen = false
    return .stop
  }

  private mutating func end() -> Command? {
    let command = turnOff()
    isEnded = true
    return command
  }
}
