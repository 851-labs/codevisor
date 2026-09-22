import CoreGraphics
import Foundation
import Testing
@testable import CodevisorCore
@testable import CodevisorUI

struct WorkspaceSplitLayoutSnapshotTests {
  private func leaf(_ id: UUID) -> SplitNode {
    .group(id: id, state: PaneGroupState(panes: [], selectedPaneId: nil))
  }

  @Test("A single leaf fills the whole frame with no dividers")
  func singleLeaf() {
    let id = UUID()
    let snapshot = WorkspaceSplitLayoutSnapshot.make(node: leaf(id), size: CGSize(width: 800, height: 600))
    #expect(snapshot.leaves.map(\.id) == [id])
    #expect(snapshot.leaves[0].frame == CGRect(x: 0, y: 0, width: 800, height: 600))
    #expect(snapshot.dividers.isEmpty)
  }

  @Test("A horizontal split tiles two leaves side by side around a 1pt divider")
  func horizontalSplit() {
    let left = UUID()
    let right = UUID()
    let node = SplitNode.split(
      orientation: .horizontal,
      children: [SplitChild(fraction: 0.5, node: leaf(left)), SplitChild(fraction: 0.5, node: leaf(right))]
    )
    let snapshot = WorkspaceSplitLayoutSnapshot.make(
      node: node, size: CGSize(width: 801, height: 600), minChildWidth: 0, minChildHeight: 0
    )
    #expect(snapshot.leaves.map(\.id) == [left, right])
    #expect(snapshot.leaves[0].frame == CGRect(x: 0, y: 0, width: 400, height: 600))
    #expect(snapshot.leaves[1].frame == CGRect(x: 401, y: 0, width: 400, height: 600))
    #expect(snapshot.dividers.count == 1)
    let divider = snapshot.dividers[0]
    #expect(divider.isHorizontal)
    #expect(divider.lineFrame == CGRect(x: 400, y: 0, width: 1, height: 600))
    #expect(divider.beforeLeafID == left)
    #expect(divider.afterLeafID == right)
    #expect(divider.id == .init(branchPath: [], childIndex: 0))
  }

  @Test("Nested splits keep every leaf as a sibling with a branch path per divider")
  func nestedSplit() {
    let a = UUID()
    let b = UUID()
    let c = UUID()
    let node = SplitNode.split(
      orientation: .horizontal,
      children: [
        SplitChild(fraction: 0.5, node: leaf(a)),
        SplitChild(
          fraction: 0.5,
          node: .split(
            orientation: .vertical,
            children: [SplitChild(fraction: 0.5, node: leaf(b)), SplitChild(fraction: 0.5, node: leaf(c))]
          )
        ),
      ]
    )
    let snapshot = WorkspaceSplitLayoutSnapshot.make(
      node: node, size: CGSize(width: 801, height: 601), minChildWidth: 0, minChildHeight: 0
    )
    #expect(snapshot.leaves.map(\.id) == [a, b, c])
    #expect(snapshot.leaves[1].frame == CGRect(x: 401, y: 0, width: 400, height: 300))
    #expect(snapshot.leaves[2].frame == CGRect(x: 401, y: 301, width: 400, height: 300))
    #expect(snapshot.dividers.map(\.branchPath) == [[], [1]])
    #expect(snapshot.dividers[1].isHorizontal == false)
  }

  @Test("Minimum child sizes floor the fractions so a starved pane stays usable")
  func minimumChildFloor() {
    let left = UUID()
    let right = UUID()
    let node = SplitNode.split(
      orientation: .horizontal,
      children: [SplitChild(fraction: 0.9, node: leaf(left)), SplitChild(fraction: 0.1, node: leaf(right))]
    )
    let snapshot = WorkspaceSplitLayoutSnapshot.make(
      node: node, size: CGSize(width: 1001, height: 600), minChildWidth: 300, minChildHeight: 0
    )
    #expect(snapshot.leaves[1].frame.width == 300)
    #expect(snapshot.leaves[0].frame.width == 700)
  }
}
