import Foundation
import Testing
@testable import CodevisorCore

@Suite("Split tree")
struct SplitTreeTests {
  private func groupState(_ terminals: Int = 1) -> PaneGroupState {
    var state = PaneGroupState()
    for _ in 0..<terminals {
      state.addTerminalPane(sessionId: UUID())
    }
    return state
  }

  @Test("Codable round-trips a nested tree")
  func codableRoundTrip() throws {
    let tree = SplitNode.split(
      orientation: .horizontal,
      children: [
        SplitChild(fraction: 0.5, node: .leaf(groupState())),
        SplitChild(
          fraction: 0.5,
          node: .split(
            orientation: .vertical,
            children: [
              SplitChild(fraction: 0.3, node: .leaf(groupState(2))),
              SplitChild(fraction: 0.7, node: .leaf(groupState())),
            ])),
      ])
    let decoded = try JSONDecoder().decode(
      SplitNode.self,
      from: JSONEncoder().encode(tree)
    )
    #expect(decoded == tree)
  }

  @Test("Splitting a lone leaf wraps it in a split, new group after for trailing")
  func splitLeafTrailing() {
    let leafId = UUID()
    let newId = UUID()
    let tree = SplitNode.leaf(groupState(), id: leafId)
    let result = tree.splitting(
      groupId: leafId, edge: .trailing, newGroupId: newId, newGroupState: groupState()
    )
    guard case let .split(orientation, children) = result else {
      Issue.record("expected split")
      return
    }
    #expect(orientation == .horizontal)
    #expect(children.count == 2)
    #expect(children.map(\.fraction) == [0.5, 0.5])
    guard case let .group(firstId, _) = children[0].node,
      case let .group(secondId, _) = children[1].node
    else {
      Issue.record("expected group leaves")
      return
    }
    #expect(firstId == leafId)
    #expect(secondId == newId)
  }

  @Test("Splitting before with top uses vertical orientation, new group first")
  func splitLeafTop() {
    let leafId = UUID()
    let newId = UUID()
    let result = SplitNode.leaf(groupState(), id: leafId).splitting(
      groupId: leafId, edge: .top, newGroupId: newId, newGroupState: groupState()
    )
    guard case let .split(orientation, children) = result,
      case let .group(firstId, _) = children[0].node
    else {
      Issue.record("expected split")
      return
    }
    #expect(orientation == .vertical)
    #expect(firstId == newId)
  }

  @Test("Same-orientation split gains a sibling instead of nesting")
  func splitSameOrientationInsertsSibling() {
    let a = UUID(), b = UUID(), c = UUID()
    let tree = SplitNode.split(
      orientation: .horizontal,
      children: [
        SplitChild(fraction: 0.5, node: .leaf(groupState(), id: a)),
        SplitChild(fraction: 0.5, node: .leaf(groupState(), id: b)),
      ])
    let result = tree.splitting(
      groupId: b, edge: .trailing, newGroupId: c, newGroupState: groupState()
    )
    guard case let .split(_, children) = result else {
      Issue.record("expected split")
      return
    }
    #expect(children.count == 3)
    #expect(children.map(\.fraction) == [0.5, 0.25, 0.25])
    #expect(result.allGroups.map(\.id) == [a, b, c])
  }

  @Test("Removing a group collapses single-child splits")
  func removeCollapses() {
    let a = UUID(), b = UUID()
    let tree = SplitNode.split(
      orientation: .horizontal,
      children: [
        SplitChild(fraction: 0.6, node: .leaf(groupState(), id: a)),
        SplitChild(fraction: 0.4, node: .leaf(groupState(), id: b)),
      ])
    let result = tree.removingGroup(id: b)
    guard case let .group(remaining, _)? = result else {
      Issue.record("expected collapsed leaf")
      return
    }
    #expect(remaining == a)
  }

  @Test("Removing survivors renormalizes fractions")
  func removeRenormalizes() {
    let a = UUID(), b = UUID(), c = UUID()
    let tree = SplitNode.split(
      orientation: .horizontal,
      children: [
        SplitChild(fraction: 0.5, node: .leaf(groupState(), id: a)),
        SplitChild(fraction: 0.25, node: .leaf(groupState(), id: b)),
        SplitChild(fraction: 0.25, node: .leaf(groupState(), id: c)),
      ])
    guard case let .split(_, children)? = tree.removingGroup(id: a) else {
      Issue.record("expected split")
      return
    }
    #expect(children.map(\.fraction) == [0.5, 0.5])
  }

  @Test("Removing the last group yields nil")
  func removeLast() {
    let a = UUID()
    #expect(SplitNode.leaf(groupState(), id: a).removingGroup(id: a) == nil)
  }

  @Test("Replacing nested split fractions preserves leaf identity")
  func replaceNestedSplitFractions() {
    let a = UUID(), b = UUID(), c = UUID()
    let tree = SplitNode.split(
      orientation: .horizontal,
      children: [
        SplitChild(fraction: 0.6, node: .leaf(groupState(), id: a)),
        SplitChild(
          fraction: 0.4,
          node: .split(
            orientation: .vertical,
            children: [
              SplitChild(fraction: 0.5, node: .leaf(groupState(), id: b)),
              SplitChild(fraction: 0.5, node: .leaf(groupState(), id: c)),
            ])),
      ])

    let result = tree.replacingSplitFractions(at: [1], with: [0.25, 0.75])

    #expect(result.allGroups.map(\.id) == [a, b, c])
    guard case let .split(_, rootChildren) = result,
      case let .split(_, nestedChildren) = rootChildren[1].node
    else {
      Issue.record("expected nested split")
      return
    }
    #expect(rootChildren.map(\.fraction) == [0.6, 0.4])
    #expect(nestedChildren.map(\.fraction) == [0.25, 0.75])
  }

  @Test("Moving a group reorders siblings and preserves identity and state")
  func moveGroupAmongSiblings() {
    let a = UUID(), b = UUID(), c = UUID()
    let aState = groupState(2)
    let tree = SplitNode.split(
      orientation: .horizontal,
      children: [
        SplitChild(fraction: 0.4, node: .leaf(aState, id: a)),
        SplitChild(fraction: 0.3, node: .leaf(groupState(), id: b)),
        SplitChild(fraction: 0.3, node: .leaf(groupState(), id: c)),
      ])

    let moved = tree.movingGroup(id: a, relativeTo: b, edge: .trailing)

    #expect(moved.allGroups.map(\.id) == [b, a, c])
    #expect(moved.group(id: a) == aState)
    guard case let .split(orientation, children) = moved else {
      Issue.record("expected horizontal split")
      return
    }
    #expect(orientation == .horizontal)
    #expect(children.count == 3)
    #expect(abs(children.map(\.fraction).reduce(0, +) - 1) < 0.0001)
  }

  @Test("Moving a nested group collapses its old parent and inserts on the target edge")
  func moveNestedGroup() {
    let a = UUID(), b = UUID(), c = UUID()
    let tree = SplitNode.split(
      orientation: .horizontal,
      children: [
        SplitChild(
          fraction: 0.7,
          node: .split(
            orientation: .vertical,
            children: [
              SplitChild(fraction: 0.5, node: .leaf(groupState(), id: a)),
              SplitChild(fraction: 0.5, node: .leaf(groupState(), id: b)),
            ])),
        SplitChild(fraction: 0.3, node: .leaf(groupState(), id: c)),
      ])

    let moved = tree.movingGroup(id: c, relativeTo: a, edge: .top)

    guard case let .split(orientation, children) = moved else {
      Issue.record("expected collapsed vertical root")
      return
    }
    #expect(orientation == .vertical)
    #expect(children.count == 3)
    #expect(moved.allGroups.map(\.id) == [c, a, b])
  }

  @Test("Invalid and self-targeted group moves are no-ops")
  func invalidGroupMoves() {
    let a = UUID(), b = UUID()
    let tree = SplitNode.split(
      orientation: .horizontal,
      children: [
        SplitChild(fraction: 0.5, node: .leaf(groupState(), id: a)),
        SplitChild(fraction: 0.5, node: .leaf(groupState(), id: b)),
      ])

    #expect(tree.movingGroup(id: a, relativeTo: a, edge: .leading) == tree)
    #expect(tree.movingGroup(id: UUID(), relativeTo: b, edge: .leading) == tree)
    #expect(tree.movingGroup(id: a, relativeTo: UUID(), edge: .leading) == tree)
  }

  @Test("Pruning removes empty groups and collapses their splits")
  func pruneEmptyGroups() {
    let chat = UUID(), empty = UUID(), terminal = UUID()
    // horizontal[vertical[chat | EMPTY] | terminal] — the stale shape an
    // interrupted drop leaves behind.
    let tree = SplitNode.split(
      orientation: .horizontal,
      children: [
        SplitChild(
          fraction: 0.5,
          node: .split(
            orientation: .vertical,
            children: [
              SplitChild(fraction: 0.75, node: .leaf(groupState(), id: chat)),
              SplitChild(fraction: 0.25, node: .leaf(PaneGroupState(), id: empty)),
            ])),
        SplitChild(fraction: 0.5, node: .leaf(groupState(), id: terminal)),
      ])
    let pruned = tree.prunedEmptyGroups
    #expect(pruned?.allGroups.map(\.id) == [chat, terminal])
    // The vertical split collapsed into the chat leaf.
    guard case let .split(orientation, children)? = pruned else {
      Issue.record("expected split")
      return
    }
    #expect(orientation == .horizontal)
    #expect(children.count == 2)
    // A tree of only empty groups prunes to nil; a healthy tree is
    // returned unchanged.
    #expect(SplitNode.leaf(PaneGroupState()).prunedEmptyGroups == nil)
    #expect(pruned?.prunedEmptyGroups == pruned)
  }

  @Test("Fraction floors protect starved children and stay proportional")
  func flooredFractions() {
    // Nothing starved: untouched.
    #expect(SplitNode.flooredFractions([0.5, 0.5], minFraction: 0.2) == [0.5, 0.5])

    // One starved child rises to the floor; the others shrink
    // proportionally (2:1 between them) and everything still sums to 1.
    let floored = SplitNode.flooredFractions([0.6, 0.3, 0.1], minFraction: 0.2)
    let expectedFirst = 8.0 / 15
    let expectedSecond = 4.0 / 15
    let flooredSum = floored.reduce(0, +)
    #expect(floored[2] == 0.2)
    #expect(abs(floored[0] - expectedFirst) < 0.0001)
    #expect(abs(floored[1] - expectedSecond) < 0.0001)
    #expect(abs(flooredSum - 1) < 0.0001)

    // Clamping can starve the next child (waterfall): both floors hold.
    let cascade = SplitNode.flooredFractions([0.7, 0.21, 0.09], minFraction: 0.25)
    #expect(cascade[1] == 0.25)
    #expect(cascade[2] == 0.25)
    #expect(abs(cascade[0] - 0.5) < 0.0001)

    // Infeasible floor (n·min > 1): equal shares.
    let equal = SplitNode.flooredFractions([0.8, 0.1, 0.1], minFraction: 0.4)
    let third = 1.0 / 3
    #expect(equal == [third, third, third])

    // Degenerate inputs pass through.
    #expect(SplitNode.flooredFractions([], minFraction: 0.2) == [])
    #expect(SplitNode.flooredFractions([0.3, 0.7], minFraction: 0) == [0.3, 0.7])
  }

  @Test("updatingGroup replaces only the target")
  func updateGroup() {
    let a = UUID(), b = UUID()
    let tree = SplitNode.split(
      orientation: .vertical,
      children: [
        SplitChild(fraction: 0.5, node: .leaf(groupState(1), id: a)),
        SplitChild(fraction: 0.5, node: .leaf(groupState(1), id: b)),
      ])
    let sessionId = UUID()
    let updated = tree.updatingGroup(id: b) { state in
      var state = state
      state.addTerminalPane(sessionId: sessionId)
      return state
    }
    #expect(updated.group(id: a)?.panes.count == 1)
    #expect(updated.group(id: b)?.panes.count == 2)
  }
}
