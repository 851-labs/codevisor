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

  @Test("Answers keep option order, carry notes, and use typed text as an Other answer")
  func answers() {
    let draft = QuestionDraft(request: QuestionRequest(questionId: "q", questions: [database, checks]))
    #expect(!draft.isSubmittable)

    draft.toggle("Tests", in: checks)
    draft.toggle("Lint", in: checks)
    draft.revealNote(for: checks)
    draft.setNote("  only fast ones ", for: checks)
    draft.toggle(QuestionDraft.otherToken, in: database)
    #expect(!draft.isSubmittable)

    draft.setNote("DuckDB", for: database)
    #expect(draft.isSubmittable)
    #expect(
      draft.answers == [
        "db": QuestionAnswerEntry(answers: ["DuckDB"]),
        "checks": QuestionAnswerEntry(answers: ["Lint", "Tests"], note: "only fast ones"),
      ])
  }

  @Test("Choosing another option drops the Other answer, and paging stays within the questions")
  func singleSelectAndPaging() {
    let draft = QuestionDraft(request: QuestionRequest(questionId: "q", questions: [database, checks]))
    draft.toggle(QuestionDraft.otherToken, in: database)
    draft.setNote("DuckDB", for: database)

    draft.toggle("SQLite", in: database)
    draft.move(by: -1)
    draft.move(by: 1)
    draft.move(by: 1)

    #expect(draft.note(for: database).isEmpty)
    #expect(draft.answers == ["db": QuestionAnswerEntry(answers: ["SQLite"])])
    #expect(draft.page == 1)
    #expect(draft.isLastPage)
    #expect(draft.isPagingForward)
  }
}
