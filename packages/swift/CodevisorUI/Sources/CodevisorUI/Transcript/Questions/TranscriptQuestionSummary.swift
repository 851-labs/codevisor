import ACPKit
import TranscriptKit

public struct TranscriptQuestionSummary: Equatable, Sendable {
  public enum Status: Equatable, Sendable {
    case answered
    case dismissed
    case timedOut
  }

  public struct Line: Equatable, Sendable, Identifiable {
    public let id: String
    public let question: String
    public let answer: TranscriptQuestionAnswer
  }

  public let status: Status
  public let lines: [Line]
  public let questionCount: Int

  public init(_ question: TranscriptQuestion) {
    status = Self.status(of: question.answer?.outcome)
    questionCount = question.request.questions.count
    lines = question.request.questions.compactMap { spec in
      question.answer?.entries[spec.id].flatMap { Self.line(spec, $0) }
    }
  }

  public var title: String {
    switch status {
    case .answered: answeredTitle
    case .dismissed: questionCount == 1 ? "Question dismissed" : "Questions dismissed"
    case .timedOut: "No answer · the agent moved on"
    }
  }

  private var answeredTitle: String {
    switch lines.count {
    case 0: "Answered"
    case 1: "Answered 1 question"
    default: "Answered \(lines.count) questions"
    }
  }

  private static func status(of outcome: QuestionOutcome?) -> Status {
    switch outcome {
    case .answered, nil: .answered
    case .cancelled, .replied: .dismissed
    case .autoResolved: .timedOut
    }
  }

  private static func line(_ spec: QuestionSpec, _ entry: QuestionAnswerEntry) -> Line? {
    let answer = TranscriptQuestionAnswer(spec, entry)
    guard !answer.isEmpty else { return nil }
    return Line(id: spec.id, question: spec.question, answer: answer)
  }
}
