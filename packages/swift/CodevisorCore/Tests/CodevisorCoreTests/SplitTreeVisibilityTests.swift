import Foundation
import Testing
@testable import CodevisorCore

@Suite("Split tree visibility")
struct SplitTreeVisibilityTests {
  private let a = UUID(), b = UUID(), c = UUID(), d = UUID()

  private func leaf(_ id: UUID) -> SplitNode {
    .group(id: id, state: PaneGroupState())
  }

  private func row(_ fractions: [Double], _ nodes: [SplitNode]) -> SplitNode {
    .split(orientation: .horizontal, children: zip(fractions, nodes).map { SplitChild(fraction: $0, node: $1) })
  }

  private func fractions(_ node: SplitNode) -> [Double] {
    guard case let .split(_, children) = node else { return [] }
    return children.map(\.fraction)
  }

  @Test("Hiding a leaf gives its share to the remaining siblings")
  func hidingReflowsSiblings() {
    let tree = row([0.5, 0.25, 0.25], [leaf(a), leaf(b), leaf(c)])

    let visible = SplitTreeVisibility.visible(tree, hiding: [b])

    #expect(visible.map { $0.allGroups.map(\.id) } == [a, c])
    #expect(visible.map(fractions) == [2.0 / 3.0, 1.0 / 3.0])
  }

  @Test("Hiding every leaf leaves nothing to show")
  func hidingEverything() {
    #expect(SplitTreeVisibility.visible(row([0.5, 0.5], [leaf(a), leaf(b)]), hiding: [a, b]) == nil)
  }

  @Test("Resizing the visible splits keeps the hidden leaf's place and share")
  func restoringResize() {
    let full = row([0.5, 0.25, 0.25], [leaf(a), leaf(b), leaf(c)])
    let resized = row([0.25, 0.75], [leaf(a), leaf(c)])

    let restored = SplitTreeVisibility.restoring([b], in: full, from: resized)

    #expect(restored.allGroups.map(\.id) == [a, b, c])
    #expect(fractions(restored) == [0.1875, 0.25, 0.5625])
  }

  @Test("A branch collapsed by hiding takes the resize of the leaf it became")
  func restoringCollapsedBranch() {
    let column = SplitNode.split(
      orientation: .vertical,
      children: [SplitChild(fraction: 0.5, node: leaf(b)), SplitChild(fraction: 0.5, node: leaf(c))]
    )
    let full = row([0.5, 0.5], [leaf(a), column])
    let resized = row([0.7, 0.3], [leaf(a), leaf(c)])

    let restored = SplitTreeVisibility.restoring([b], in: full, from: resized)

    #expect(fractions(restored) == [0.7, 0.3])
    guard case let .split(_, children) = restored else {
      Issue.record("expected split")
      return
    }
    #expect(children[1].node == column)
  }

  @Test("A visible tree that no longer matches the hidden layout is ignored")
  func restoringMismatchKeepsFullTree() {
    let full = row([0.5, 0.25, 0.25], [leaf(a), leaf(b), leaf(c)])
    let reshaped = row([0.4, 0.3, 0.3], [leaf(a), leaf(c), leaf(d)])

    #expect(SplitTreeVisibility.restoring([b], in: full, from: reshaped) == full)
  }
}
