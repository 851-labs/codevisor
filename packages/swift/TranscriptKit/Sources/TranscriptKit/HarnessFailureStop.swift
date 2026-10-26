public enum HarnessFailureStop: String, Sendable {
  case forbidden
  case harnessFailed
}

extension AssistantTurn {
  public var harnessFailure: HarnessFailureStop? {
    stopKind.flatMap(HarnessFailureStop.init(rawValue:))
  }
}
