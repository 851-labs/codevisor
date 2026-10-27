import ACPKit
import TranscriptKit

public struct TranscriptQuestionSummary: Equatable, Sendable {
  public enum Status: Equatable, Sendable {
    case answered
    case replied
    case dismissed
    case timedOut
  }

  public struct Line: Equatable, Sendable, Identifiable {
    public let id: String
    public let question: String
    public let answer: String
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
    case .answered: lines.isEmpty ? "Answered" : "You answered"
    case .replied: "Skipped · you replied instead"
    case .dismissed: questionCount == 1 ? "Question dismissed" : "Questions dismissed"
    case .timedOut: "No answer · the agent moved on"
    }
  }

  public var symbolName: String {
    switch status {
    case .answered: "checkmark.circle.fill"
    case .replied: "arrowshape.turn.up.left.circle"
    case .dismissed, .timedOut: "minus.circle"
    }
  }

  private static func status(of outcome: QuestionOutcome?) -> Status {
    switch outcome {
    case .answered, nil: .answered
    case .replied: .replied
    case .cancelled: .dismissed
    case .autoResolved: .timedOut
    }
  }

  private static func line(_ spec: QuestionSpec, _ entry: QuestionAnswerEntry) -> Line? {
    let answer = answerText(entry)
    guard !answer.isEmpty else { return nil }
    return Line(id: spec.id, question: spec.header ?? spec.question, answer: answer)
  }

  private static func answerText(_ entry: QuestionAnswerEntry) -> String {
    let labels = entry.answers.joined(separator: ", ")
    let note = entry.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if labels.isEmpty { return note }
    if note.isEmpty { return labels }
    return "\(labels) — \(note)"
  }
}
