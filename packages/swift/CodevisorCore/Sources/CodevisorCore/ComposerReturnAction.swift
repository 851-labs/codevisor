public enum ComposerReturnAction: Equatable, Sendable {
  case send
  case insertNewline
  case queue

  public init(shift: Bool, option: Bool, command: Bool) {
    if shift || option {
      self = .insertNewline
    } else if command {
      self = .queue
    } else {
      self = .send
    }
  }
}
