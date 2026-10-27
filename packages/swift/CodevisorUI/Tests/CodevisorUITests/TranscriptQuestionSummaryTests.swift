import ACPKit
import Testing
import TranscriptKit

@testable import CodevisorUI

struct TranscriptQuestionSummaryTests {
  private let questions = [
    QuestionSpec(id: "db", header: "Database", question: "Which database?"),
    QuestionSpec(id: "tests", question: "Add tests?"),
    QuestionSpec(id: "deploy", question: "Deploy now?"),
  ]

  private func summary(
    _ outcome: QuestionOutcome, _ entries: [String: QuestionAnswerEntry] = [:]
  )
    -> TranscriptQuestionSummary
  {
    TranscriptQuestionSummary(
      TranscriptQuestion(
        request: QuestionRequest(questionId: "q", questions: questions),
        answer: .init(outcome: outcome, entries: entries)))
  }

  @Test("Answers read as the question's header or text followed by the choices and the note")
  func answeredLines() {
    let answered = summary(
      .answered,
      [
        "tests": QuestionAnswerEntry(answers: [], note: "Only unit tests"),
        "db": QuestionAnswerEntry(answers: ["Postgres", "Redis"], note: "keep it local"),
        "deploy": QuestionAnswerEntry(answers: [], note: "  "),
      ])

    #expect(answered.status == .answered)
    #expect(answered.title == "You answered")
    #expect(
      answered.lines.map { [$0.question, $0.answer] } == [
        ["Database", "Postgres, Redis — keep it local"],
        ["Add tests?", "Only unit tests"],
      ])
  }

  @Test("Questions resolved without answers say how they ended")
  func unansweredTitles() {
    #expect(summary(.replied).title == "Skipped · you replied instead")
    #expect(summary(.cancelled).title == "Questions dismissed")
    #expect(summary(.autoResolved).title == "No answer · the agent moved on")
    #expect(summary(.answered).title == "Answered")
    #expect(summary(.replied).lines.isEmpty)
  }
}
