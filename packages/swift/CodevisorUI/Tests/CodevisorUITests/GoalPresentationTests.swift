import ACPKit
import Testing

@testable import CodevisorUI

@Suite("Goal presentation")
struct GoalPresentationTests {
  @Test("Every goal status has concise user-facing copy")
  func statusText() {
    #expect(GoalPresentation.statusText(for: .active) == "Active")
    #expect(GoalPresentation.statusText(for: .paused) == "Paused")
    #expect(GoalPresentation.statusText(for: .blocked) == "Blocked")
    #expect(GoalPresentation.statusText(for: .usageLimited) == "Usage limited")
    #expect(GoalPresentation.statusText(for: .budgetLimited) == "Budget limited")
    #expect(GoalPresentation.statusText(for: .complete) == "Complete")
  }

  @Test("Token counts remain compact without empty decimal fractions")
  func tokenFormatting() {
    #expect(GoalPresentation.tokens(999) == "999")
    #expect(GoalPresentation.tokens(1_500) == "1.5k")
    #expect(GoalPresentation.tokens(10_000) == "10k")
    #expect(GoalPresentation.tokens(1_200_000) == "1.2M")
  }

  @Test("Elapsed goal time uses completed compact units")
  func elapsedFormatting() {
    #expect(GoalPresentation.elapsed(-1) == "0s")
    #expect(GoalPresentation.elapsed(59.9) == "59s")
    #expect(GoalPresentation.elapsed(90) == "1m")
    #expect(GoalPresentation.elapsed(5_400) == "1h 30m")
    #expect(GoalPresentation.elapsed(93_784) == "1d 2h 3m")
  }

  @Test("Goal usage combines only metrics that have values")
  func usageFormatting() {
    #expect(
      GoalPresentation.usageText(
        for: SessionGoal(objective: "Ship", status: .active)
      ) == nil
    )
    #expect(
      GoalPresentation.usageText(
        for: SessionGoal(
          objective: "Ship",
          status: .active,
          tokensUsed: 12_000,
          timeUsedSeconds: 90
        )
      ) == "12k tokens · 1m"
    )
  }
}
