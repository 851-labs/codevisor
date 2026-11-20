enum BotMascotMotion: Equatable, Sendable {
  case watching
  case idle
  case working
  case calling
  case waiting
  case sleeping

  init(_ activity: BotMascotActivity, isOpen: Bool) {
    if activity.isInTurn {
      self = activity.isTalkingToAgent ? .calling : .working
    } else if isOpen {
      self = .watching
    } else if activity.hasWorkingAgents {
      self = .waiting
    } else {
      self = activity.staysAwake ? .idle : .sleeping
    }
  }

  var riveMode: String {
    switch self {
    case .watching, .idle: "idle"
    case .working: "working"
    case .calling: "calling"
    case .waiting: "waiting"
    case .sleeping: "sleeping"
    }
  }

  var followsPointer: Bool { self == .watching }

  var olderFileStandIn: BotMascotMotion {
    self == .waiting ? .idle : self
  }
}
