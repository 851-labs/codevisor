import Foundation
import Testing
@testable import CodevisorCore

@Suite("Shared workspace sidebar positions")
struct WorkspaceSidebarOrderTests {
  private func workspace(_ number: Int, time: TimeInterval) -> Workspace {
    Workspace(
      id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!,
      name: "Workspace", rootDirectory: nil, serverId: number.isMultiple(of: 2) ? "remote" : "local",
      projectId: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
      centerTabs: [WorkspaceTab(root: .leaf(PaneGroupState()))],
      createdAt: Date(timeIntervalSince1970: time), isServerSynced: true
    )
  }

  @Test func initialPositionsMatchTheWireFormat() {
    let row = workspace(1, time: 0)
    #expect(row.effectiveSidebarPosition == "ffffffffffff8000000000000000000000000000000018")
    #expect(WorkspacePosition.isValid(row.effectiveSidebarPosition))
  }

  @Test func everyVisibleSubsetPreservesRelativeOrder() {
    let rows = [workspace(1, time: 10), workspace(2, time: 20), workspace(3, time: 30), workspace(4, time: 40)]
    let sorted = rows.sorted(by: WorkspaceSidebarOrder.precedes)
    for mask in 0..<16 {
      let visible = rows.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
      let visibleIDs = Set(visible.map(\.id))
      #expect(
        visible.sorted(by: WorkspaceSidebarOrder.precedes).map(\.id)
          == sorted.filter { visibleIDs.contains($0.id) }.map(\.id))
    }
  }

  @Test func movingOnlyOneRowPreservesHiddenPositions() throws {
    var rows = [workspace(1, time: 40), workspace(2, time: 30), workspace(3, time: 20), workspace(4, time: 10)]
    let hidden = rows[1]
    let moved = try #require(
      WorkspaceSidebarOrder.position(for: rows[3].id, in: [rows[0].id, rows[3].id, rows[2].id], workspaces: rows))
    rows[3].sidebarPosition = moved
    let visible = rows.filter { $0.id != hidden.id }.sorted(by: WorkspaceSidebarOrder.precedes)
    #expect(visible.map(\.id) == [rows[0].id, rows[3].id, rows[2].id])
    #expect(rows[1] == hidden)
  }

  @Test func newWorkspacePrecedesRepeatedManualMovesToTheTop() throws {
    var head = workspace(1, time: 100).effectiveSidebarPosition
    let id = workspace(2, time: 100).id
    for _ in 0..<100 {
      let next = try #require(WorkspacePosition.between(nil, head, id: id))
      #expect(next < head)
      #expect(WorkspacePosition.epoch(next) == WorkspacePosition.epoch(head))
      head = next
    }
    let newest = WorkspacePosition.initial(createdAt: Date(timeIntervalSince1970: 99), id: id, after: head)
    #expect(newest < head)
  }

  @Test func newWorkspaceUsesTheObservedFrontierBeforeItIsSaved() {
    let head = workspace(1, time: 100).effectiveSidebarPosition
    let created = Workspace(
      name: "New", rootDirectory: nil, serverId: "local", projectId: workspace(1, time: 0).projectId,
      centerTabs: [WorkspaceTab(root: .leaf(PaneGroupState()))],
      createdAt: Date(timeIntervalSince1970: 99), sidebarOrderHead: head
    )
    #expect(created.effectiveSidebarPosition < head)
    let repository = DefaultWorkspaceRepository(store: InMemoryStore())
    repository.save(created)
    #expect(repository.workspace(id: created.id) == created)
  }

  @Test func concurrentGapInsertionsRemainDistinctAndCanBeReordered() throws {
    let lower = workspace(1, time: 20).effectiveSidebarPosition
    let upper = workspace(2, time: 10).effectiveSidebarPosition
    let a = try #require(WorkspacePosition.between(lower, upper, id: workspace(3, time: 0).id))
    let b = try #require(WorkspacePosition.between(lower, upper, id: workspace(4, time: 0).id))
    #expect(lower < a && a < b && b < upper)
    let middle = try #require(WorkspacePosition.between(a, b, id: workspace(5, time: 0).id))
    #expect(a < middle && middle < b)
    #expect(WorkspacePosition.isValid(middle))
  }

  @Test func invalidNeighborsDoNotCorruptOrdering() {
    let id = workspace(1, time: 0).id
    #expect(WorkspacePosition.between("invalid", nil, id: id) == nil)
    let key = workspace(2, time: 0).effectiveSidebarPosition
    #expect(WorkspacePosition.between(key, key, id: id) == nil)
  }
}
