import Testing
@testable import CodevisorUI

struct ChildAgentsSummaryTests {
  private struct Child {
    let isWorking: Bool
    var harnessId: String? = "codex"
  }

  private let working = Child(isWorking: true)
  private let idle = Child(isWorking: false)

  private func summary(_ children: [Child]) -> ChildAgentsSummary? {
    ChildAgentsSummary(children, isWorking: \.isWorking, harnessId: \.harnessId)
  }

  @Test func countsEveryChild() {
    #expect(summary([working, idle, working, idle])?.count == 4)
  }

  @Test func oneChildIsSingular() {
    #expect(summary([idle])?.title == "1 Agent")
  }

  @Test func severalChildrenArePlural() {
    #expect(summary([idle, idle, idle])?.title == "3 Agents")
  }

  @Test func isWorkingWhileAnyChildIsWorking() {
    #expect(summary([idle, working, idle])?.isWorking == true)
  }

  @Test func isIdleWhenNoChildIsWorking() {
    #expect(summary([idle, idle])?.isWorking == false)
  }

  @Test func isHiddenWithoutChildren() {
    #expect(summary([]) == nil)
  }

  @Test func sharesTheHarnessEveryChildUses() {
    #expect(summary([idle, idle])?.sharedHarnessId == "codex")
  }

  @Test func hasNoSharedHarnessForMixedChildren() {
    let claude = Child(isWorking: false, harnessId: "claude-code")
    let workspace = Child(isWorking: false, harnessId: nil)

    #expect(summary([idle, claude])?.sharedHarnessId == nil)
    #expect(summary([idle, workspace])?.sharedHarnessId == nil)
  }
}
