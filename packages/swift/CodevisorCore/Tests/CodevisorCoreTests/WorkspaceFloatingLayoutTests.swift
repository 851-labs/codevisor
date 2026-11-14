import Foundation
import Testing
@testable import CodevisorCore

@Suite("Workspace floating layout")
struct WorkspaceFloatingLayoutTests {
  private let a = UUID(), b = UUID(), c = UUID()

  private func workspace(_ leaves: [UUID]) -> Workspace {
    let children = leaves.map {
      SplitChild(fraction: 1 / Double(leaves.count), node: .group(id: $0, state: PaneGroupState()))
    }
    return Workspace(
      name: "Workspace", rootDirectory: nil, serverId: "local", projectId: UUID(),
      centerTree: .split(orientation: .horizontal, children: children)
    )
  }

  @Test("A flagged leaf floats and leaves the visible tree")
  func flaggedLeafFloats() {
    let workspace = workspace([a, b, c])

    let layout = WorkspaceFloatingLayout(workspace: workspace, flagged: [b])

    #expect(layout.floating == [b])
    #expect(layout.stale.isEmpty)
  }

  @Test("A flag for a leaf that left the workspace is stale")
  func vanishedLeafIsStale() {
    let gone = UUID()

    let layout = WorkspaceFloatingLayout(workspace: workspace([a, b]), flagged: [b, gone])

    #expect(layout.floating == [b])
    #expect(layout.stale == [gone])
  }

  @Test("A tab never floats all of its leaves, so it always shows one")
  func lastLeavesDock() {
    let workspace = workspace([a, b])

    let layout = WorkspaceFloatingLayout(workspace: workspace, flagged: [a, b])

    #expect(layout.floating.isEmpty)
    #expect(layout.stale == [a, b])
  }

  @Test("Only a docked leaf with a docked sibling can float")
  func canFloatNeedsADockedSibling() {
    let tree = workspace([a, b, c]).centerTree
    let layout = WorkspaceFloatingLayout(workspace: workspace([a, b, c]), flagged: [b])

    #expect(layout.canFloat(a, in: tree))
    #expect(!layout.canFloat(b, in: tree))
    #expect(!layout.canFloat(UUID(), in: tree))
    let pair = workspace([a, b])
    #expect(!WorkspaceFloatingLayout(workspace: pair, flagged: [b]).canFloat(a, in: pair.centerTree))
  }
}
