public enum ServerBotMascotPart: Sendable {
  case hat
  case eyewear

  public var item: WritableKeyPath<ServerBotMascot, String> {
    switch self {
    case .hat: \.hat
    case .eyewear: \.eyewear
    }
  }

  public var color: WritableKeyPath<ServerBotMascot, String> {
    switch self {
    case .hat: \.hatColor
    case .eyewear: \.eyewearColor
    }
  }
}
