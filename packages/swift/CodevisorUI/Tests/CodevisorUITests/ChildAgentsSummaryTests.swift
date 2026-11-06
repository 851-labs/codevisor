import Testing
@testable import CodevisorUI

struct ChildAgentsSummaryTests {
  private struct Child {
    let isWorking: Bool
  }

  private let working = Child(isWorking: true)
  private let idle = Child(isWorking: false)

  private func summary(_ children: [Child]) -> ChildAgentsSummary? {
    ChildAgentsSummary(children, isWorking: \.isWorking)
  }

  @Test func countsOnlyWorkingChildren() {
    #expect(summary([working, idle, working, idle])?.workingCount == 2)
  }

  @Test func oneWorkingChildIsSingular() {
    #expect(summary([idle, working])?.title == "1 Agent")
  }

  @Test func severalWorkingChildrenArePlural() {
    #expect(summary([working, working, working])?.title == "3 Agents")
  }

  @Test func isHiddenWhenNoChildIsWorking() {
    #expect(summary([idle, idle]) == nil)
    #expect(summary([]) == nil)
  }
}
