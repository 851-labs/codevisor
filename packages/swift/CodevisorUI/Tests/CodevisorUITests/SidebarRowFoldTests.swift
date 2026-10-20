import Testing
@testable import CodevisorUI

struct SidebarRowFoldTests {
  private func plan(_ previous: [String], _ current: [String]) -> [String] {
    SidebarRowFold.plan(from: previous, to: current).map { step in
      switch step.fold {
      case .kept: step.id
      case .arriving: "+" + step.id
      case .leaving: "-" + step.id
      }
    }
  }

  @Test("Collapsing keeps the folding rows where they were, around the selected row that stays")
  func leavingRowsKeepTheirPlace() {
    #expect(
      plan(["list", "mac", "a", "b", "selected", "c", "cloud", "d"], ["list", "mac", "selected", "cloud", "d"])
        == ["list", "mac", "-a", "-b", "selected", "-c", "cloud", "d"])
  }

  @Test("Rows leaving from the top stay above the first row that remains")
  func leavingRowsAtTheTop() {
    #expect(plan(["a", "b", "c"], ["c"]) == ["-a", "-b", "c"])
  }

  @Test("Expanding marks the new rows as arriving in their final order")
  func arrivingRows() {
    #expect(
      plan(["list", "mac", "selected"], ["list", "mac", "a", "selected", "b"]) == [
        "list", "mac", "+a", "selected", "+b",
      ])
  }

  @Test("A row that changes section folds out of the old one and into the new one (851-2786)")
  func sectionChangeIsOutAndIn() {
    #expect(
      plan(["pinned", "list", "mac", "a@list", "b@list"], ["pinned", "a@pinned", "list", "mac", "b@list"])
        == ["pinned", "+a@pinned", "list", "mac", "-a@list", "b@list"])
  }

  @Test("Reordering kept rows plans no folds")
  func reorderOnly() {
    #expect(plan(["a", "b", "c"], ["c", "a", "b"]) == ["c", "a", "b"])
  }
}
