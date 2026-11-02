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
    Row(name: "nothing started", actual: [:], shown: [.running, .pending, .pending, .pending]),
    Row(
      name: "a later step finished first",
      actual: [.server: .done, .harnesses: .running, .projects: .running, .models: .done],
      shown: [.done, .running, .pending, .pending]
    ),
    Row(
      name: "a skipped step hands the spinner to the next one",
      actual: [.server: .done, .harnesses: .skipped, .projects: .done, .models: .running],
      shown: [.done, .skipped, .done, .running]
    ),
    Row(
      name: "the last blocker finishing reveals everything below it at once",
      actual: [.server: .done, .harnesses: .done, .projects: .done, .models: .done],
      shown: [.done, .done, .done, .done]
    ),
    Row(
      name: "an unfinished step keeps the steps below it quiet",
      actual: [.server: .running, .harnesses: .done, .projects: .skipped, .models: .done],
      shown: [.running, .pending, .pending, .pending]
    ),
  ]

  @Test("Reveals finished steps top to bottom with one spinner at a time", arguments: rows)
  func revealsInOrder(row: Row) {
    let revealed = FirstLaunchReveal.revealed(row.actual)
    #expect(FirstLaunchStep.allCases.map { revealed[$0] } == row.shown)
    #expect(revealed.values.filter { $0 == .running }.count <= 1)
  }
}

@Suite("First-launch step details")
struct FirstLaunchDetailTests {
  @Test(
    "Lists found names with shorter summaries to fall back on instead of truncating",
    arguments: [(FirstLaunchStep.harnesses, "harness", "harnesses"), (.projects, "project", "projects")]
  )
  func nameCandidates(step: FirstLaunchStep, singular: String, plural: String) {
    #expect(
      FirstLaunchDetail.candidates(for: step, names: ["Claude Code", "Codex", "Pi", "Muse Code"]) == [
        "Claude Code, Codex, Pi, and Muse Code",
        "Claude Code, Codex, Pi +1",
        "Claude Code, Codex +2",
        "Claude Code +3",
        "4 \(plural)",
      ]
    )
    #expect(FirstLaunchDetail.candidates(for: step, names: ["Codex"]) == ["Codex", "1 \(singular)"])
    #expect(FirstLaunchDetail.candidates(for: step, names: []).isEmpty)
  }

  @Test("Has nothing to list for steps that find nothing", arguments: [FirstLaunchStep.server, .models])
  func noCandidates(step: FirstLaunchStep) {
    #expect(FirstLaunchDetail.candidates(for: step, names: ["Codex"]).isEmpty)
  }
}
