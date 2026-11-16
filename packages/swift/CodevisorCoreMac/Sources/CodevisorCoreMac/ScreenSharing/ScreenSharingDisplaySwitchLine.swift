public enum ScreenSharingDisplaySwitchLine: Equatable, Sendable {
  case switching(String)
  case failed(String)

  public var text: String {
    switch self {
    case .switching(let text), .failed(let text): text
    }
  }
}
