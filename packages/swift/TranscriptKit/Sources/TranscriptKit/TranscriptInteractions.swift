import ACPKit

public struct TranscriptInteractions: Sendable, Equatable {
  public private(set) var items: [TranscriptInteraction]

  public init(_ items: [TranscriptInteraction] = []) {
    self.items = items
  }

  public var isEmpty: Bool { items.isEmpty }

  public var shownInTranscript: [TranscriptInteraction] {
    items.filter(\.isShownInTranscript)
  }

  public func contains(id: String) -> Bool {
    items.contains { $0.id == id }
  }

  public func interaction(id: String) -> TranscriptInteraction? {
    items.first { $0.id == id }
  }

  mutating func ask(_ request: QuestionRequest) {
    guard !contains(id: request.questionId) else { return }
    items.append(
      TranscriptInteraction(id: request.questionId, content: .question(TranscriptQuestion(request: request))))
  }

  mutating func resolve(_ resolution: QuestionResolution) {
    let answer = TranscriptQuestion.Answer(outcome: resolution.outcome, entries: resolution.answers ?? [:])
    guard let index = items.firstIndex(where: { $0.id == resolution.questionId }) else {
      let request = QuestionRequest(questionId: resolution.questionId, questions: resolution.questions)
      items.append(
        TranscriptInteraction(id: request.questionId, content: .question(.init(request: request, answer: answer))))
      return
    }
    guard case var .question(question) = items[index].content else { return }
    question.answer = answer
    items[index].content = .question(question)
  }

  public mutating func adoptMissing(from other: TranscriptInteractions) -> Bool {
    let missing = other.items.filter { !contains(id: $0.id) }
    items += missing
    return !missing.isEmpty
  }
}
