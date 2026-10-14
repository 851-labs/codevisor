import CoreGraphics
import Testing
@testable import CodevisorUI

struct ListReorderTests {
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
    #expect(ListReorder.destinationIndex(of: "b", in: order, frames: frames, midY: 249) == 1)
    #expect(ListReorder.destinationIndex(of: "b", in: order, frames: frames, midY: 251) == 2)
    #expect(ListReorder.destinationIndex(of: "b", in: order, frames: frames, midY: 51) == 1)
    #expect(ListReorder.destinationIndex(of: "b", in: order, frames: frames, midY: 49) == 0)
  }

  @Test func tallNeighborsDoNotOscillateAcrossAReflow() {
    let short: CGFloat = 40
    let tall: CGFloat = 300
    let before = stacked([("a", short), ("tall", tall)])
    let ghostMidY = before["tall"]!.midY + 1
    #expect(ListReorder.destinationIndex(of: "a", in: ["a", "tall"], frames: before, midY: ghostMidY) == 1)

    let after = stacked([("tall", tall), ("a", short)])
    #expect(ListReorder.destinationIndex(of: "a", in: ["tall", "a"], frames: after, midY: ghostMidY) == 1)

    let backUp = after["tall"]!.midY - 1
    #expect(ListReorder.destinationIndex(of: "a", in: ["tall", "a"], frames: after, midY: backUp) == 0)
  }

  @Test func incompleteGeometryNeverMoves() {
    let frames = stacked([("a", 100), ("b", 100)])
    #expect(ListReorder.destinationIndex(of: "b", in: ["a", "b", "c"], frames: frames, midY: 500) == nil)
    #expect(ListReorder.destinationIndex(of: "zzz", in: ["a", "b"], frames: frames, midY: 50) == nil)
  }

  @Test func theDraggedRowsOwnFrameIsIgnored() {
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

  @Test func movingWithinAGroupKeepsOtherRowsInPlace() {
    let order = ["a", "B", "b", "C", "c"]
    let lower = ["a", "b", "c"]
    #expect(ListReorder.moving("c", to: 0, within: lower, in: order) == ["c", "B", "a", "C", "b"])
    #expect(ListReorder.moving("a", to: 2, within: lower, in: order) == ["b", "B", "c", "C", "a"])
    #expect(ListReorder.moving("b", to: 1, within: lower, in: order) == order)
    #expect(ListReorder.moving("C", to: 0, within: ["B", "C"], in: order) == ["a", "C", "b", "B", "c"])
  }
}
