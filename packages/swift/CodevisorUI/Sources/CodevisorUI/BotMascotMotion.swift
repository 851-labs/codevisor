import CodevisorCore

public enum BotMascotMotion: Sendable {
  case still
  case idle
  case working
  case calling

  var riveMode: BotMascotRiveMode? {
    switch self {
    case .still: nil
    case .idle: .idle
    case .working: .working
    case .calling: .calling
    }
  }
}
