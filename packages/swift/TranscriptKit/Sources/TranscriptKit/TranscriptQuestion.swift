import ACPKit

public struct TranscriptQuestion: Sendable, Equatable {
  public struct Answer: Sendable, Equatable {
    public var outcome: QuestionOutcome
    public var entries: [String: QuestionAnswerEntry]

    public init(outcome: QuestionOutcome, entries: [String: QuestionAnswerEntry] = [:]) {
      self.outcome = outcome
      self.entries = entries
    }
  }

  public var request: QuestionRequest
  public var answer: Answer?

  public init(request: QuestionRequest, answer: Answer? = nil) {
    self.request = request
    self.answer = answer
  }

  public static func asksInTranscript(_ questions: [QuestionSpec]) -> Bool {
    !questions.isEmpty
      && TranscriptSetupRequest.kind(of: questions) == nil
      && !questions.contains { $0.id == QuestionRequest.exitPlanModeId }
  }
}
