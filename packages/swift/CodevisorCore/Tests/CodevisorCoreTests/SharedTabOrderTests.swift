import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorClient
@testable import CodevisorCore

/// Tab order is shared across devices; splits stay per device.
@MainActor
struct SharedTabOrderTests {
  private let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
  private let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
  private let third = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

  @Test("Midpoint keys match the server's digit for digit")
  func positionsMatchServer() {
    // The same vectors are asserted in packages/api/src/workspace-position.test.ts.
    let lower = WorkspacePosition.initial(createdAt: Date(timeIntervalSince1970: 0.2), id: first)
    let upper = WorkspacePosition.initial(createdAt: Date(timeIntervalSince1970: 0.1), id: second)
    #expect(lower == "ffffffffff378000000000000000000000000000000018")
    #expect(WorkspacePosition.between(lower, upper, id: third) == "ffffffffff68000000000000000000000000000000038")
    #expect(WorkspacePosition.between(upper, nil, id: third) == "ffffffffffc8000000000000000000000000000000038")
    #expect(WorkspacePosition.between(nil, lower, id: third) == "ffffffffff3748000000000000000000000000000000038")
  }

  @Test("Tabs sort by their shared keys; the local New Tab page keeps its slot")
  func tabsSortBySharedKeys() {
    let (tabs, panes) = tabs(count: 3)
    let local = WorkspaceTab.placeholder()
    let positions = [panes[0]: "c000000000008", panes[1]: "a000000000008", panes[2]: "b000000000008"]
    let sorted = SharedTabOrder.sorted([tabs[0], local, tabs[1], tabs[2]], positions: positions)
    #expect(sorted.map(\.id) == [tabs[1].id, local.id, tabs[2].id, tabs[0].id])
  }

  @Test("Moving one tab rewrites only that tab's key, and every device sorts to the new order")
  func movingATabRewritesOneKey() {
    let (tabs, panes) = tabs(count: 3)
    var positions = [panes[0]: "a000000000008", panes[1]: "b000000000008", panes[2]: "c000000000008"]
    let wanted = [tabs[2], tabs[0], tabs[1]]
    let moves = SharedTabOrder.moves(for: wanted, positions: positions)
    #expect(moves.map(\.paneId) == [panes[2]])
    for move in moves { positions[move.paneId] = move.position }
    #expect(SharedTabOrder.sorted(tabs, positions: positions).map(\.id) == wanted.map(\.id))
  }

  @Test("A split tab moves as one; another device showing its panes as tabs keeps them together")
  func splitTabMovesTogether() {
    let (tabs, panes) = tabs(count: 3)
    var positions = [panes[0]: "a000000000008", panes[1]: "b000000000008", panes[2]: "c000000000008"]
    let split = WorkspaceTab(
      root: .split(
        orientation: .horizontal,
        children: [tabs[1].root, tabs[2].root].map { SplitChild(fraction: 0.5, node: $0) }))
    let moves = SharedTabOrder.moves(for: [split, tabs[0]], positions: positions)
    #expect(Set(moves.map(\.paneId)) == [panes[1], panes[2]])
    for move in moves { positions[move.paneId] = move.position }
    // The device without the split sorts the three panes as tabs.
    #expect(SharedTabOrder.sorted(tabs, positions: positions).map(\.id) == [tabs[1].id, tabs[2].id, tabs[0].id])
  }

  @Test("A tab drag reaches the server as shared keys and survives the server's echo")
  func tabDragSyncs() async throws {
    let terminal = PaneDescriptorState(id: UUID(), kind: .terminal, name: "Terminal", terminalKey: "t1")
    let browser = PaneDescriptorState(id: UUID(), kind: .browser, name: "Docs", terminalKey: "b1")
    let fixture = await WorkspaceSyncFixture { workspace, _ in
      workspace.centerTabs += [terminal, browser].map {
        WorkspaceTab(root: .leaf(PaneGroupState(panes: [$0], selectedPaneId: $0.id)))
      }
    }
    fixture.server.assignTabOrder([fixture.anchorSessionId, terminal.id, browser.id])
    await fixture.deliver()
    let paneOrder = { (fixture.current?.centerTabs ?? []).flatMap(SharedTabOrder.paneIds(of:)) }
    #expect(paneOrder() == [fixture.anchorSessionId, terminal.id, browser.id])

    let terminalTab = try #require(fixture.current?.centerTabs[1].id)
    let firstTab = try #require(fixture.current?.centerTabs[0].id)
    fixture.sync.moveTab(terminalTab, before: firstTab, inWorkspace: fixture.workspace.id)
    #expect(paneOrder() == [terminal.id, fixture.anchorSessionId, browser.id])
    #expect(fixture.store.pendingIntents.count == 1)

    fixture.connect()
    await fixture.settle()
    #expect(fixture.server.requests == ["movePane"])
    #expect(fixture.store.pendingIntents.isEmpty)
    #expect(paneOrder() == [terminal.id, fixture.anchorSessionId, browser.id])
  }

  @Test("A dropped row lands before the next other tab, whole splits included")
  func droppedRowSuccessor() {
    let (a, b, c) = (UUID(), UUID(), UUID())
    let rows = [a, b, b, c]
    #expect(SharedTabOrder.successor(of: c, droppedAt: 0, rowTabIds: rows) == a)
    #expect(SharedTabOrder.successor(of: a, droppedAt: 3, rowTabIds: rows) == c)
    #expect(SharedTabOrder.successor(of: a, droppedAt: 4, rowTabIds: rows) == nil)
    #expect(SharedTabOrder.successor(of: b, droppedAt: 1, rowTabIds: rows) == c)
  }

  @Test("Another device's tab move reorders this device's tabs")
  func remoteTabMoveApplies() async throws {
    let terminal = PaneDescriptorState(id: UUID(), kind: .terminal, name: "Terminal", terminalKey: "t1")
    let fixture = await WorkspaceSyncFixture { workspace, _ in
      workspace.centerTabs.append(
        WorkspaceTab(root: .leaf(PaneGroupState(panes: [terminal], selectedPaneId: terminal.id))))
    }
    fixture.server.assignTabOrder([terminal.id, fixture.anchorSessionId])
    await fixture.deliver()
    #expect(fixture.current?.centerTabs.flatMap(SharedTabOrder.paneIds(of:)) == [terminal.id, fixture.anchorSessionId])
    #expect(fixture.store.pendingIntents.isEmpty)
  }

  private func tabs(count: Int) -> ([WorkspaceTab], [UUID]) {
    let panes = (0..<count).map { index in
      PaneDescriptorState(id: UUID(), kind: .terminal, name: "T\(index)", terminalKey: "t\(index)")
    }
    let tabs = panes.map { WorkspaceTab(root: .leaf(PaneGroupState(panes: [$0], selectedPaneId: $0.id))) }
    return (tabs, panes.map(\.id))
  }
}
