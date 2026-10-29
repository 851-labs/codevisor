enum PlayerError: Error, CustomStringConvertible {
  case noScreen
  case screenLocked
  case displayMismatch(String)
  case virtualDisplayUnavailable(String)

  var description: String {
    switch self {
    case .noScreen: "There is no display to play on."
    case .screenLocked: "The GUI session is locked, so macOS won't show the player's frames. Unlock it first."
    case .displayMismatch(let message), .virtualDisplayUnavailable(let message): message
    }
  }
}
