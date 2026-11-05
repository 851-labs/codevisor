enum BotMascotMotion: String, Equatable, Sendable {
  case idle
  case working
  case calling
  case sleeping

  init(_ activity: BotMascotActivity, isOpen: Bool) {
    if activity.isWaitingOnAgents {
      self = .calling
    } else if activity.isWorking {
      self = .working
    } else {
      self = isOpen ? .idle : .sleeping
    }
  }

  var followsPointer: Bool { self == .idle }
}
