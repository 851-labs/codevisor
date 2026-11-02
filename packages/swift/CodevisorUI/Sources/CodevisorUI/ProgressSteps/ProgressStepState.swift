public enum ProgressStepState: Equatable, Sendable {
  case pending
  case running
  case done
  case skipped
  case failed

  var accessibilityValue: String {
    switch self {
    case .pending: "Waiting"
    case .running: "In progress"
    case .done: "Done"
    case .skipped: "Skipped"
    case .failed: "Failed"
    }
  }
}
