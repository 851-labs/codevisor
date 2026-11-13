import CodevisorClient

enum ScreenSharingHostEnding: Equatable, Sendable {
  case stoppedOnHost
  case displayAsleep
  case sessionSwitched
  case displayGone
  case captureLost
  case takenOver(by: String?)
  case failed(String)

  var reason: ServerScreenSharingReason? {
    switch self {
    case .stoppedOnHost: .stoppedOnHost
    case .displayAsleep: .displayAsleep
    case .sessionSwitched: .sessionSwitched
    case .displayGone: .noDisplay
    case .takenOver: .takenOver
    case .captureLost, .failed: nil
    }
  }

  var message: String {
    switch self {
    case .stoppedOnHost, .displayAsleep, .sessionSwitched, .displayGone, .captureLost:
      "Screen sharing was stopped on the host Mac."
    case .takenOver(let name?): "Now viewing on \(name)."
    case .takenOver(nil): "Now viewing on another device."
    case .failed(let message): message
    }
  }

  static func reply(
    to owner: ScreenSharingHostLease.Owner, lastEnd: (owner: ScreenSharingHostLease.Owner, ending: Self)?,
    holder: ScreenSharingHostLease.Owner?
  ) -> ServerScreenSharingReply {
    if let lastEnd, lastEnd.owner == owner { return lastEnd.ending.reply }
    if let holder, holder.appKey != nil, holder != owner { return takenOver(by: holder.name).reply }
    return .init(status: "stopped", message: "Screen sharing ended on the host Mac.")
  }

  var reply: ServerScreenSharingReply {
    var reply = ServerScreenSharingReply(status: "failed", message: message)
    reply.reason = reason
    if case .takenOver(let name) = self { reply.holderName = name }
    return reply
  }
}
