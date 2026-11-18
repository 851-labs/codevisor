import CodevisorClient

enum ScreenSharingHostEnding: Equatable, Sendable {
  case stoppedOnHost
  case displayAsleep
  case sessionSwitched
  case displayGone
  case captureLost
  case takenOver(by: String?)
  case captureRefused
  case failed(String)

  static func captureFailed(_ failure: ScreenSharingHostFailure) -> Self {
    if failure.isRefusedCapture { return .captureRefused }

    return .failed(failure.sentence ?? ScreenSharingHostService.captureFailed)
  }

  var reason: ServerScreenSharingReason? {
    switch self {
    case .stoppedOnHost: .stoppedOnHost
    case .displayAsleep: .displayAsleep
    case .sessionSwitched: .sessionSwitched
    case .displayGone: .noDisplay
    case .takenOver: .takenOver
    case .captureRefused: .permissionMissing
    case .captureLost, .failed: nil
    }
  }

  var message: String {
    switch self {
    case .stoppedOnHost, .displayAsleep, .sessionSwitched, .displayGone, .captureLost:
      "Screen sharing was stopped on the host Mac."
    case .takenOver(let name?): "Now viewing on \(name)."
    case .takenOver(nil): "Now viewing on another device."
    case .captureRefused: ScreenSharingHostRefusal.permissionMessage
    case .failed(let message): message
    }
  }

  var waitsForAnOpen: Bool {
    switch self {
    case .stoppedOnHost, .displayAsleep, .sessionSwitched: true
    case .displayGone, .captureLost, .takenOver, .captureRefused, .failed: false
    }
  }

  var reply: ServerScreenSharingReply {
    var reply = ServerScreenSharingReply(status: "failed", message: message)
    reply.reason = reason
    if case .takenOver(let name) = self { reply.holderName = name }
    return reply
  }
}
