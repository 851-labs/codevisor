import Testing

@testable import CodevisorCore

@Suite("First-launch reveal order")
struct FirstLaunchRevealTests {
  struct Row: CustomTestStringConvertible, Sendable {
    let name: String
    let actual: [FirstLaunchStep: FirstLaunchStepOutcome]
    let shown: [FirstLaunchStepOutcome]
    var testDescription: String { name }
  }

  static let rows = [
    Row(name: "nothing started", actual: [:], shown: [.pending, .pending, .pending, .pending]),
    Row(
      name: "a later step finished first",
      actual: [.server: .done, .harnesses: .running, .projects: .running, .models: .done],
      shown: [.done, .running, .running, .running]
    ),
    Row(
      name: "a skipped step lets the ones below it show",
      actual: [.server: .done, .harnesses: .skipped, .projects: .done, .models: .running],
      shown: [.done, .skipped, .done, .running]
    ),
    Row(
      name: "the last blocker finishing reveals everything below it at once",
      actual: [.server: .done, .harnesses: .done, .projects: .done, .models: .done],
      shown: [.done, .done, .done, .done]
    ),
    Row(
      name: "an unfinished step keeps finished steps below it hidden",
      actual: [.server: .running, .harnesses: .done, .projects: .skipped, .models: .done],
      shown: [.running, .running, .running, .running]
    ),
  ]

  @Test("Reveals finished steps strictly top to bottom", arguments: rows)
  func revealsInOrder(row: Row) {
    let revealed = FirstLaunchReveal.revealed(row.actual)
    #expect(FirstLaunchStep.allCases.map { revealed[$0] } == row.shown)
  }
}

@Suite("First-launch step details")
struct FirstLaunchDetailTests {
  @Test("Offers shorter harness summaries to fall back on instead of truncating")
  func harnessCandidates() {
    #expect(
      FirstLaunchDetail.candidates(harnesses: ["Claude Code", "Codex", "Pi", "Muse Code"]) == [
        "Claude Code, Codex, Pi, and Muse Code",
        "Claude Code, Codex, Pi +1",
        "Claude Code, Codex +2",
        "Claude Code +3",
        "4 harnesses",
      ]
    )
    #expect(FirstLaunchDetail.candidates(harnesses: ["Codex"]) == ["Codex", "1 harness"])
    #expect(FirstLaunchDetail.candidates(harnesses: []).isEmpty)
  }

  @Test("Confirms found projects and says nothing when there were none")
  func projectCandidates() {
    #expect(FirstLaunchDetail.candidates(projects: 6) == ["6 projects"])
    #expect(FirstLaunchDetail.candidates(projects: 1) == ["1 project"])
    #expect(FirstLaunchDetail.candidates(projects: 0).isEmpty)
  }
}
