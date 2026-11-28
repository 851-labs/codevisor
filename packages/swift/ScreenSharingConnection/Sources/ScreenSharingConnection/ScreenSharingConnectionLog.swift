import OSLog

@MainActor
struct ScreenSharingConnectionLog {
  typealias Event = ScreenSharingConnectionStateMachine.Event
  typealias Command = ScreenSharingConnectionStateMachine.Command

  private static let logger = Logger(subsystem: "com.851labs.Codevisor", category: "ScreenSharing")

  private let name: String

  init(machineId: String, target: String?) {
    name = "Connection to \([machineId, target].compactMap(\.self).joined(separator: " "))"
  }

  func note(
    _ event: Event, from before: ScreenSharingConnectionState, to after: ScreenSharingConnectionState,
    then command: Command?
  ) {
    let (was, now, quietWait) = (Self.kind(of: before), Self.kind(of: after), Self.quietWait(of: command))
    guard was != now || quietWait != nil else { return }

    let change = was == now ? "still \(now)" : "\(was) → \(now)"
    let next = quietWait.map { "; trying again quietly in \($0.components.seconds) s" } ?? ""
    Self.logger.notice(
      "\(name, privacy: .public): \(change, privacy: .public) (\(Self.cause(event), privacy: .public))\(next, privacy: .public)"
    )
  }

  func lingering() {
    let linger = ScreenSharingConnectionDeadlines.linger.components.seconds
    Self.logger.notice(
      "\(name, privacy: .public): nothing on screen; turning off in \(linger) s unless a surface is shown")
  }

  private static func quietWait(of command: Command?) -> Duration? {
    guard case .stopAndTryQuietly(let wait) = command else { return nil }

    return wait
  }

  private static func kind(of state: ScreenSharingConnectionState) -> String {
    switch state {
    case .off: "off"
    case .connecting: "connecting"
    case .live: "live"
    case .reconnecting: "reconnecting"
    case .failed(let reason): "failed (\(describe(reason)))"
    }
  }

  private static func cause(_ event: Event) -> String {
    switch event {
    case .surfacesChanged(_, let visible): visible ? "a surface came on screen" : "no surface on screen"
    case .openRequested: "Open Desktop"
    case .retryRequested: "Retry"
    case .restartRequested: "restart"
    case .displayPicked: "display picked"
    case .stepEntered: "next step"
    case .firstFrameDecoded: "first frame decoded"
    case .attemptEnded(.dropped(let reason)): "attempt dropped: \(describe(reason))"
    case .attemptEnded(.refused(let reason)): "host refused: \(describe(reason))"
    case .attemptEnded(.hostFailed(let message)): "host failed: \(message ?? "no message")"
    case .stayedLive: "stayed live"
    case .unseenBrieflyElapsed:
      "nothing on screen for \(ScreenSharingConnectionDeadlines.unseenDebounce.components.seconds) s"
    case .lingerElapsed: "nothing on screen for the linger"
    case .machineCameOnline: "machine back online"
    case .machineStillReady: "machine still ready"
    case .targetAppeared: "target appeared"
    case .systemWoke: "this device woke"
    case .ended: "ended"
    }
  }

  private static func describe(_ reason: ScreenSharingFailureReason) -> String {
    switch reason {
    case .cantReach: "can't reach"
    case .takenOver(let holder): "taken over by \(holder ?? "another device")"
    case .inUse(let holder): "in use on \(holder ?? "another device")"
    case .stoppedOnHost: "stopped on host"
    case .displayAsleep: "display asleep"
    case .sessionSwitched: "another user logged in"
    case .noDisplay: "no display"
    case .nothingToView(let message): "nothing to view: \(message ?? "no message")"
    case .unsupportedOnThisDevice: "unsupported on this device"
    case .permissionMissing: "permission missing"
    case .updateNeeded: "update needed"
    case .networkBlocked: "no video connection"
    case .noVideo: "no picture"
    case .keptDropping: "kept dropping"
    case .unclassified(let message): message ?? "no message"
    }
  }
}
