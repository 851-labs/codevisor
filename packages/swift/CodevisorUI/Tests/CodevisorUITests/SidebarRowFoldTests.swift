import CoreGraphics
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

  @Test("Rows still folding out from an earlier change keep their place when the next change lands")
  func inFlightRowsKeepTheirPlace() {
    #expect(
      SidebarRowFold.interleave(["-b"], into: ["a", "c", "d"], by: ["a", "-b", "c", "d"]) { $0 }
        == ["a", "-b", "c", "d"])
    #expect(
      SidebarRowFold.interleave(["-a", "-c"], into: ["d"], by: ["-a", "b", "-c", "d"]) { $0 }
        == ["-a", "-c", "d"])
    #expect(SidebarRowFold.interleave(["-x"], into: ["a"], by: ["a"]) { $0 } == ["a", "-x"])
  }
}

struct SidebarRowFoldInterruptionTests {
  private typealias Placement = SidebarRowFold.Placement<String>

  private func shown(_ ids: [String]) -> [Placement] {
    ids.map { Placement($0, .shown) }
  }

  private func values(_ rows: [Placement], at progress: [CGFloat]) -> [String: CGFloat] {
    Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.visibility.value(at: SidebarFoldProgress(progress))) })
  }

  @Test("Expanding a section mid-collapse continues each row from where it is")
  func reverseCollapseMidFold() {
    let collapsing = SidebarRowFold.plan(from: shown(["pinned", "a", "b", "list"]), to: ["pinned", "list"], fold: 0)
    #expect(values(collapsing, at: [0.25]) == ["pinned": 1, "a": 0.75, "b": 0.75, "list": 1])

    let reopening = SidebarRowFold.plan(from: collapsing, to: ["pinned", "a", "b", "list"], fold: 1)
    #expect(reopening.map(\.id) == ["pinned", "a", "b", "list"])
    #expect(values(reopening, at: [0.25, 0]) == values(collapsing, at: [0.25]))
    #expect(values(reopening, at: [1, 1]) == ["pinned": 1, "a": 1, "b": 1, "list": 1])
    #expect(reopening.map(\.visibility.target) == [1, 1, 1, 1])
  }

  @Test("Collapsing a section mid-expand continues each row from where it is")
  func reverseExpandMidFold() {
    let expanding = SidebarRowFold.plan(from: shown(["pinned", "list"]), to: ["pinned", "a", "b", "list"], fold: 0)
    #expect(values(expanding, at: [0.5]) == ["pinned": 1, "a": 0.5, "b": 0.5, "list": 1])

    let closing = SidebarRowFold.plan(from: expanding, to: ["pinned", "list"], fold: 1)
    #expect(closing.map(\.id) == ["pinned", "a", "b", "list"])
    #expect(values(closing, at: [0.5, 0]) == values(expanding, at: [0.5]))
    #expect(values(closing, at: [1, 1]) == ["pinned": 1, "a": 0, "b": 0, "list": 1])
    #expect(SidebarRowFold.settle(closing).map(\.id) == ["pinned", "list"])
  }

  @Test("Toggling a section three times mid-fold never moves a row at the moment of each toggle")
  func toggleThreeTimesFast() {
    let open = ["pinned", "a", "b", "list"]
    let closed = ["pinned", "list"]
    var rows = shown(open)
    var progress: [CGFloat] = []
    for (fold, (target, reached)) in [(closed, CGFloat(0.5)), (open, 0.25), (closed, 0.75)].enumerated() {
      let before = values(rows, at: progress)
      rows = SidebarRowFold.plan(from: rows, to: target, fold: fold)
      #expect(rows.map(\.id) == open)
      #expect(values(rows, at: progress + [0]) == before)
      progress.append(reached)
    }
    #expect(values(rows, at: [1, 1, 1]) == ["pinned": 1, "a": 0, "b": 0, "list": 1])
    #expect(SidebarRowFold.settle(rows) == shown(closed))
  }

  @Test("Unpinning a row mid-pin reverses both of its folds in place (851-2786)")
  func unpinMidPin() {
    let pinning = SidebarRowFold.plan(
      from: shown(["pinned", "list", "a@list", "b@list"]), to: ["pinned", "a@pinned", "list", "b@list"], fold: 0)
    let unpinning = SidebarRowFold.plan(
      from: pinning, to: ["pinned", "list", "a@list", "b@list"], fold: 1)
    #expect(unpinning.map(\.id) == ["pinned", "a@pinned", "list", "a@list", "b@list"])
    #expect(
      values(unpinning, at: [0.75, 0]) == ["pinned": 1, "a@pinned": 0.75, "list": 1, "a@list": 0.25, "b@list": 1])
    #expect(SidebarRowFold.settle(unpinning) == shown(["pinned", "list", "a@list", "b@list"]))
  }

  @Test("A row that keeps its target through a later fold keeps folding on its own")
  func unrelatedFoldLeavesRowsAlone() {
    let collapsing = SidebarRowFold.plan(
      from: shown(["pinned", "a", "list", "b"]), to: ["pinned", "list", "b"], fold: 0)
    let next = SidebarRowFold.plan(from: collapsing, to: ["pinned", "list"], fold: 1)
    #expect(next.map(\.id) == ["pinned", "a", "list", "b"])
    #expect(next.first { $0.id == "a" } == collapsing.first { $0.id == "a" })
  }
}
