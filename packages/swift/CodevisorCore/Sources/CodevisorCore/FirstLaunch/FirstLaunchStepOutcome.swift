public enum FirstLaunchStepOutcome: Equatable, Sendable {
  case pending
  case running
  case done
  case skipped

  public var isComplete: Bool {
    self == .done || self == .skipped
  }
}
