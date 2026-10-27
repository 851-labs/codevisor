import ACPKit
import Foundation
import Testing

@testable import TranscriptKit

struct TranscriptQuestionReductionTests {
  @Test("Agent questions become a transcript interaction that records how they were answered")
  func transcriptQuestions() {
    let questions = [QuestionSpec(id: "db", question: "Which database?", options: [QuestionOption(label: "Postgres")])]
    let request = QuestionRequest(questionId: "q", message: "Before I start", questions: questions)
    var turn = AssistantTurn()
    turn.isThinking = true

    TranscriptReducer.apply(.question(request), to: &turn)
    TranscriptReducer.apply(.question(request), to: &turn)
    #expect(!turn.isThinking)
    #expect(turn.interactions.items == [TranscriptInteraction(id: "q", content: .question(.init(request: request)))])

    let answers = ["db": QuestionAnswerEntry(answers: ["Postgres"])]
    TranscriptReducer.apply(
      .questionResolved(
        QuestionResolution(questionId: "q", outcome: .answered, questions: questions, answers: answers)),
      to: &turn)
    TranscriptReducer.apply(
      .questionResolved(QuestionResolution(questionId: "late", outcome: .replied, questions: questions)), to: &turn)

    #expect(
      turn.interactions.items == [
        TranscriptInteraction(
          id: "q", content: .question(.init(request: request, answer: .init(outcome: .answered, entries: answers)))),
        TranscriptInteraction(
          id: "late",
          content: .question(
            .init(request: QuestionRequest(questionId: "late", questions: questions), answer: .init(outcome: .replied)))
        ),
      ])
    #expect(turn.entries.isEmpty)
  }
}
