import CoreGraphics
import Testing
@testable import CodevisorUI

struct ListReorderTests {
  /// Rows stacked from y = 0 with the given heights, keyed by name.
  private func stacked(_ rows: [(String, CGFloat)]) -> [String: CGRect] {
    var frames: [String: CGRect] = [:]
    var y: CGFloat = 0
    for (id, height) in rows {
      frames[id] = CGRect(x: 0, y: y, width: 200, height: height)
      y += height
    }
    return frames
  }

  @Test func staysPutUntilTheGhostCrossesANeighborMidpoint() {
    let order = ["a", "b", "c"]
    let frames = stacked([("a", 100), ("b", 100), ("c", 100)])
    // "c" spans 200–300, midpoint 250.
    #expect(ListReorder.destinationIndex(of: "b", in: order, frames: frames, midY: 249) == 1)
    #expect(ListReorder.destinationIndex(of: "b", in: order, frames: frames, midY: 251) == 2)
    // "a" spans 0–100, midpoint 50.
    #expect(ListReorder.destinationIndex(of: "b", in: order, frames: frames, midY: 51) == 1)
    #expect(ListReorder.destinationIndex(of: "b", in: order, frames: frames, midY: 49) == 0)
  }

  @Test func tallNeighborsDoNotOscillateAcrossAReflow() {
    // Dragging a short row down past a tall one: once it has crossed the
    // tall row's midpoint and the list reflows, the tall row's NEW
    // midpoint must still be above the ghost, so the decision holds.
    let short: CGFloat = 40
    let tall: CGFloat = 300
    let before = stacked([("a", short), ("tall", tall)])
    let ghostMidY = before["tall"]!.midY + 1
    #expect(ListReorder.destinationIndex(of: "a", in: ["a", "tall"], frames: before, midY: ghostMidY) == 1)

    let after = stacked([("tall", tall), ("a", short)])
    #expect(ListReorder.destinationIndex(of: "a", in: ["tall", "a"], frames: after, midY: ghostMidY) == 1)

    // And dragging back up needs the ghost above the tall row's new
    // midpoint, not merely above where it started.
    let backUp = after["tall"]!.midY - 1
    #expect(ListReorder.destinationIndex(of: "a", in: ["tall", "a"], frames: after, midY: backUp) == 0)
  }

  @Test func incompleteGeometryNeverMoves() {
    let frames = stacked([("a", 100), ("b", 100)])
    #expect(ListReorder.destinationIndex(of: "b", in: ["a", "b", "c"], frames: frames, midY: 500) == nil)
    #expect(ListReorder.destinationIndex(of: "zzz", in: ["a", "b"], frames: frames, midY: 50) == nil)
  }

  @Test func theDraggedRowsOwnFrameIsIgnored() {
    // Only the other rows' midpoints matter, so a stale frame for the
    // dragged row cannot shift the answer.
    var frames = stacked([("a", 100), ("b", 100), ("c", 100)])
    frames["b"] = CGRect(x: 0, y: -1_000, width: 200, height: 10)
    #expect(ListReorder.destinationIndex(of: "b", in: ["a", "b", "c"], frames: frames, midY: 150) == 1)
  }

  @Test func movingReordersOrLeavesTheArrayAlone() {
    #expect(ListReorder.moving("c", to: 0, in: ["a", "b", "c"]) == ["c", "a", "b"])
    #expect(ListReorder.moving("a", to: 2, in: ["a", "b", "c"]) == ["b", "c", "a"])
    #expect(ListReorder.moving("b", to: 1, in: ["a", "b", "c"]) == ["a", "b", "c"])
    #expect(ListReorder.moving("b", to: 3, in: ["a", "b", "c"]) == ["a", "b", "c"])
    #expect(ListReorder.moving("x", to: 0, in: ["a", "b", "c"]) == ["a", "b", "c"])
  }
}
