import CodevisorCore

public enum BotMascotMotion: Sendable {
  case still
  case idle
  case working

  var loop: ServerBotMascotLoop? {
    switch self {
    case .still: nil
    case .idle: .idle
    case .working: .working
    }
  }
}
