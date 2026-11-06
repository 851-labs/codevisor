enum BotMascotMotion: Equatable, Sendable {
  case watching
  case idle
  case working
  case calling
  case sleeping

  init(_ activity: BotMascotActivity, isOpen: Bool) {
    if activity.isInTurn {
      self = activity.isTalkingToAgent ? .calling : .working
    } else if isOpen {
      self = .watching
    } else {
      self = activity.hasActiveAgents ? .idle : .sleeping
    }
  }

  var riveMode: String {
    switch self {
    case .watching, .idle: "idle"
    case .working: "working"
    case .calling: "calling"
    case .sleeping: "sleeping"
    }
  }

  var followsPointer: Bool { self == .watching }
}
