import ACPKit
import Testing

@testable import CodevisorCore

@MainActor
struct QuestionDraftTests {
  private let database = QuestionSpec(
    id: "db", question: "Which database?",
    options: [QuestionOption(label: "Postgres"), QuestionOption(label: "SQLite")])
  private let checks = QuestionSpec(
    id: "checks", question: "Which checks?", options: [QuestionOption(label: "Lint"), QuestionOption(label: "Tests")],
    multiSelect: true)

  @Test("Answers keep option order and add typed text as the Other answer")
  func answers() {
    let draft = QuestionDraft(request: QuestionRequest(questionId: "q", questions: [database, checks]))
    #expect(!draft.isSubmittable)

    draft.toggle("Tests", in: checks)
    draft.toggle("Lint", in: checks)
    draft.toggle(QuestionDraft.otherToken, in: checks)
    draft.setTypedAnswer("  only fast ones ", for: checks)
    draft.toggle(QuestionDraft.otherToken, in: database)
    #expect(!draft.isSubmittable)

    draft.setTypedAnswer("DuckDB", for: database)
    #expect(draft.isSubmittable)
    #expect(
      draft.answers == [
        "db": QuestionAnswerEntry(answers: ["DuckDB"]),
        "checks": QuestionAnswerEntry(answers: ["Lint", "Tests", "only fast ones"]),
      ])
  }

  @Test("Choosing another option drops the Other answer, and paging stays within the questions")
  func singleSelectAndPaging() {
    let draft = QuestionDraft(request: QuestionRequest(questionId: "q", questions: [database, checks]))
    draft.toggle(QuestionDraft.otherToken, in: database)
    draft.setTypedAnswer("DuckDB", for: database)

    draft.toggle("SQLite", in: database)
    draft.move(by: -1)
    draft.move(by: 1)
    draft.move(by: 1)

    #expect(draft.typedAnswer(for: database).isEmpty)
    #expect(draft.answers == ["db": QuestionAnswerEntry(answers: ["SQLite"])])
    #expect(draft.page == 1)
    #expect(draft.isLastPage)
    #expect(draft.isPagingForward)
  }

  @Test("Plan feedback typed beside a chosen option is sent as its note")
  func planFeedback() {
    let plan = QuestionSpec(
      id: QuestionRequest.exitPlanModeId, question: "Ready?",
      options: [QuestionOption(label: QuestionRequest.keepPlanningLabel)], allowsOther: false)
    let draft = QuestionDraft(request: QuestionRequest(questionId: "p", questions: [plan]))

    draft.toggle(QuestionRequest.keepPlanningLabel, in: plan)
    draft.setTypedAnswer(" Split the migration ", for: plan)

    #expect(
      draft.answers == [
        plan.id: QuestionAnswerEntry(answers: [QuestionRequest.keepPlanningLabel], note: "Split the migration")
      ])
  }
}
