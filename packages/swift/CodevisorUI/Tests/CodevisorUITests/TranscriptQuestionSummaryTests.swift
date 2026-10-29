import ACPKit
import Testing
import TranscriptKit

@testable import CodevisorUI

struct TranscriptQuestionSummaryTests {
  private let questions = [
    QuestionSpec(
      id: "scope", header: "Scope", question: "What should this ticket cover?",
      options: [QuestionOption(label: "Route existing actions (Recommended)"), QuestionOption(label: "Node")]),
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

  private func answer(_ answers: [String], note: String? = nil) -> TranscriptQuestionAnswer {
    TranscriptQuestionAnswer(questions[0], QuestionAnswerEntry(answers: answers, note: note))
  }

  @Test("Answered lines pair each question with its chosen option and note as plain text")
  func answeredLines() {
    let answered = summary(
      .answered,
      [
        "tests": QuestionAnswerEntry(answers: [], note: "Only unit tests"),
        "scope": QuestionAnswerEntry(answers: ["Route existing actions (Recommended)"], note: "keep it lean"),
        "deploy": QuestionAnswerEntry(answers: [], note: "  "),
      ])

    #expect(answered.title == "Answered 2 questions")
    #expect(
      answered.lines.map { [$0.question, $0.answer.text] } == [
        ["What should this ticket cover?", "Route existing actions\nkeep it lean"],
        ["Add tests?", "Only unit tests"],
      ])
  }

  @Test("A single answered question is counted like several")
  func singleQuestionTitle() {
    #expect(summary(.answered, ["tests": QuestionAnswerEntry(answers: ["Yes"])]).title == "Answered 1 question")
  }

  @Test("A note typed after an option label splits off the option, without the Recommended marker")
  func splitsLabelFromNote() {
    let parsed = answer(["Route existing actions (Recommended). Pause/wake stay in 851-3683."])

    #expect(parsed.choices == ["Route existing actions"])
    #expect(parsed.note == "Pause/wake stay in 851-3683.")
    #expect(answer(["Route existing actions — and retire old ones"]).note == "and retire old ones")
  }

  @Test("Text that only starts with an option's letters stays custom text")
  func keepsCustomText() {
    #expect(answer(["Node.js only"]) == answer([], note: "Node.js only"))
    #expect(answer(["Nodemon"]).choices.isEmpty)
    #expect(answer(["Node: but pinned"]).choices == ["Node"])
  }

  @Test("Recommended options are recognised in any case, and a bare marker stays as typed")
  func optionLabels() {
    #expect(QuestionOptionLabel("Postgres (recommended)") == QuestionOptionLabel("Postgres (Recommended)"))
    #expect(QuestionOptionLabel("Postgres (Recommended)").title == "Postgres")
    #expect(QuestionOptionLabel("Postgres (Recommended)").isRecommended)
    #expect(!QuestionOptionLabel("(Recommended)").isRecommended)
    #expect(!QuestionOptionLabel("Postgres").isRecommended)
  }

  @Test("Questions resolved without answers say how they ended")
  func unansweredTitles() {
    #expect(summary(.cancelled).title == "Questions dismissed")
    #expect(summary(.autoResolved).title == "No answer · the agent moved on")
    #expect(summary(.answered).title == "Answered")
    #expect(summary(.cancelled).lines.isEmpty)
  }
}
