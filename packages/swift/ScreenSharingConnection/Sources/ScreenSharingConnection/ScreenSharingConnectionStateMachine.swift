import CodevisorClient
import ScreenSharingV2

struct ScreenSharingConnectionStateMachine: Equatable, Sendable {
  enum Event: Equatable, Sendable {
    case surfacesChanged(attached: Bool, visible: Bool)
    case openRequested
    case retryRequested
    case restartRequested
    case stepEntered(ScreenSharingConnectStage)
    case firstFrameDecoded
    case attemptEnded(ScreenSharingAttemptEnd)
    case stayedLive
    case unseenBrieflyElapsed
    case lingerElapsed
    case machineCameOnline
    case machineStillReady
    case targetAppeared
    case systemWoke
    case ended
  }

  enum Unseen: Equatable, Sendable {
    case briefly
    case lingering
  }

  enum Command: Equatable, Sendable {
    case start(ServerScreenSharingRequest.Intent, after: Duration, asksWhyItEnded: Bool)
    case restart
    case stop
    case stopAndTryQuietly(after: Duration)

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
  private var attemptIntent = ServerScreenSharingRequest.Intent.attach
  private var failureIsSticky = false
  private var retriedWhileReady = false
  private var keepsTrying = false
  private var quietTries = 0

  init() {}

  mutating func handle(_ event: Event, openPending: Bool = false) -> Command? {
    guard !isEnded else { return nil }

    self.openPending = openPending
    switch event {
    case .surfacesChanged(let attached, let visible): return surfacesChanged(attached: attached, visible: visible)
    case .openRequested: return userAsked()
    case .retryRequested: return attached ? userAsked() : nil
    case .restartRequested: return restart()
    case .stepEntered(let stage): return enter(stage)
    case .firstFrameDecoded: return goLive()
    case .attemptEnded(let end): return attemptEnded(end)
    case .stayedLive: return forgive()
    case .unseenBrieflyElapsed: return unseenBrieflyElapsed()
    case .lingerElapsed: return unseen == .lingering ? stopBeingUnseen() : nil
    case .machineCameOnline:
      retriedWhileReady = false
      return tryAgainNow()
    case .machineStillReady: return retryOnceWhileReady()
    case .targetAppeared: return targetAppeared()
    case .systemWoke: return woke()
    case .ended: return end()
    }
  }

  private mutating func surfacesChanged(attached: Bool, visible: Bool) -> Command? {
    self.attached = attached
    self.visible = visible
    guard visible else {
      if state != .off, unseen == nil, !staysFailed { unseen = .briefly }
      return nil
    }

    unseen = nil
    return state == .off ? connect(open: openPending) : nil
  }

  private mutating func unseenBrieflyElapsed() -> Command? {
    guard unseen == .briefly else { return nil }
    guard lingersUnseen else { return stopBeingUnseen() }

    unseen = .lingering
    return nil
  }

  private mutating func stopBeingUnseen() -> Command? {
    guard staysFailed else { return turnOff() }

    unseen = nil
    return nil
  }

  private var staysFailed: Bool {
    guard case .failed = state else { return false }

    return attached && failureIsSticky
  }

  private var lingersUnseen: Bool {
    switch state {
    case .live: true
    case .reconnecting: attached
    case .off, .connecting, .failed: false
    }
  }

  private mutating func userAsked() -> Command? {
    guard case .failed = state else { return nil }

    retriedWhileReady = false
    if !visible { unseen = .briefly }
    return connect(open: true)
  }

  private mutating func restart() -> Command? {
    switch state {
    case .live, .reconnecting:
      state = .reconnecting
      triesUsed = 1
      retriedHostFailure = false
      attemptIntent = .attach
      return .restart
    case .failed:
      return attached ? userAsked() : nil
    case .off, .connecting:
      return nil
    }
  }

  private mutating func targetAppeared() -> Command? {
    guard case .failed(.nothingToView) = state, visible else { return nil }

    return connect(open: false)
  }

  private mutating func retryOnceWhileReady() -> Command? {
    guard !retriedWhileReady, state == .failed(.cantReach) else { return nil }

    retriedWhileReady = true
    return tryAgainNow()
  }

  private mutating func tryAgainNow() -> Command? {
    guard case .failed = state, keepsTrying, visible else { return nil }

    return connect(open: false)
  }

  private mutating func woke() -> Command? {
    switch state {
    case .live: return attemptEnded(.dropped(.cantReach))
    case .reconnecting: return startOver()
    case .failed: return tryAgainNow()
    case .off, .connecting: return nil
    }
  }

  private mutating func startOver() -> Command? {
    triesUsed = 1
    return start(after: .zero, open: false)
  }

  private mutating func enter(_ stage: ScreenSharingConnectStage) -> Command? {
    if case .connecting = state { state = .connecting(stage) }
    return nil
  }

  private mutating func goLive() -> Command? {
    guard canGoLive else { return nil }

    state = .live
    retriedWhileReady = false
    keepsTrying = false
    quietTries = 0
    return nil
  }

  private var canGoLive: Bool {
    switch state {
    case .connecting, .reconnecting: true
    case .failed: keepsTrying
    case .off, .live: false
    }
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
    case (.off, _):
      return nil
    case (.failed, _):
      return quietTryEnded(end)
    case (_, .hostFailed(let message)):
      return hostFailed(message)
    case (.live, .refused(let reason)):
      return refuse(reason)
    case (.connecting, .dropped(let reason)):
      return fail(reason, keepsTrying: true)
    case (.live, .dropped):
      return reconnect()
    case (.connecting, .refused(let reason)):
      return upgradesToOpen(reason) ? connect(open: true) : refuse(reason)
    case (.reconnecting, .refused(let reason)):
      return upgradesToOpen(reason) ? start(after: .zero, open: true) : refuse(reason)
    case (.reconnecting, .dropped(let reason)):
      return nextTry(after: reason)
    }
  }

  private mutating func hostFailed(_ message: String?) -> Command? {
    let reason = ScreenSharingFailureReason.unclassified(message: message)
    if case .connecting = state { return fail(reason, keepsTrying: true) }
    guard !retriedHostFailure else { return fail(reason, keepsTrying: true) }

    retriedHostFailure = true
    return state == .live ? reconnect() : nextTry(after: reason)
  }

  private mutating func quietTryEnded(_ end: ScreenSharingAttemptEnd) -> Command? {
    guard keepsTrying else { return nil }

    switch end {
    case .refused(let reason): return refuse(reason)
    case .dropped(let reason): return fail(reason, keepsTrying: true)
    case .hostFailed(let message): return fail(.unclassified(message: message), keepsTrying: true)
    }
  }

  private func upgradesToOpen(_ reason: ScreenSharingFailureReason) -> Bool {
    openPending && attemptIntent == .attach && reason.yieldsToAnOpen
  }

  private mutating func connect(open: Bool) -> Command? {
    failureIsSticky = false
    keepsTrying = false
    quietTries = 0
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
      return fail(reason == .cantReach ? .cantReach : .keptDropping, keepsTrying: true)
    }

    triesUsed += 1
    return start(after: wait, open: openPending, asksWhyItEnded: asksWhyItEnded)
  }

  private mutating func start(after wait: Duration, open: Bool, asksWhyItEnded: Bool = false) -> Command? {
    attemptIntent = open ? .open : .attach
    return .start(attemptIntent, after: wait, asksWhyItEnded: asksWhyItEnded)
  }

  private mutating func fail(_ reason: ScreenSharingFailureReason, keepsTrying: Bool = false) -> Command? {
    if keepsTrying, !visible { return turnOff() }

    state = .failed(reason)
    failureIsSticky = reason.isDecidedByHost
    triesUsed = 0
    retriedHostFailure = false
    if staysFailed, unseen == .lingering { unseen = nil }
    self.keepsTrying = keepsTrying
    guard keepsTrying else { return .stop }

    quietTries += 1
    return .stopAndTryQuietly(after: ScreenSharingRetryPolicy.quietWait(afterTries: quietTries - 1))
  }

  private mutating func refuse(_ reason: ScreenSharingFailureReason) -> Command? {
    fail(reason, keepsTrying: reason.clearsOnTheHost)
  }

  private mutating func turnOff() -> Command? {
    guard state != .off else { return nil }

    state = .off
    failureIsSticky = false
    keepsTrying = false
    quietTries = 0
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
