public struct ProgressStep: Identifiable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let state: ProgressStepState
  public let details: [String]

  public init(id: String, title: String, state: ProgressStepState, details: [String] = []) {
    self.id = id
    self.title = title
    self.state = state
    self.details = details
  }
}
