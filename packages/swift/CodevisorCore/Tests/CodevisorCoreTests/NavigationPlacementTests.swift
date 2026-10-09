import CodevisorClient
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
struct NavigationPlacementTests {
  private static func workspace(_ id: UUID, position: String? = nil, parent: UUID? = nil) -> ServerWorkspace {
    var record = ServerWorkspace(
      id: id.uuidString, serverId: "local", projectId: UUID().uuidString, name: id.uuidString,
      hasCustomName: true, isArchived: false, createdAt: "2026-10-08T00:00:00.000Z")
    record.sidebarPosition = position
    record.parentWorkspaceId = parent?.uuidString.lowercased()
    record.parentTabPosition = parent == nil ? nil : "000000000001888"
    return record
  }

  private static func snapshot(_ workspaces: [ServerWorkspace]) -> ServerNavigationSnapshot {
    ServerNavigationSnapshot(
      eventCursor: 1, projects: [], sessions: [], workspaces: workspaces, panes: [], records: .init())
  }

  /// Valid, increasing positions.
  private static func positions(_ count: Int) -> [String] {
    var result: [String] = []
    for _ in 0..<count {
      result.append(WorkspacePosition.between(result.last, nil, id: UUID())!)
    }
    return result
  }

  private static func topLevelIds(_ store: NavigationStore) -> [UUID] {
    store.agentSidebar.compactMap { node in
      if case let .agent(row) = node { row.id } else { nil }
    }
  }

  @Test("A dropped index takes the positions of the items around it")
  func neighbors() {
    #expect(NavigationStore.neighbors(at: 0, in: ["a", "b"])! == (nil, "a"))
    #expect(NavigationStore.neighbors(at: 1, in: ["a", "b"])! == ("a", "b"))
    #expect(NavigationStore.neighbors(at: 5, in: ["a", "b"])! == ("b", nil))
    #expect(NavigationStore.neighbors(at: 0, in: [])! == (nil, nil))
    #expect(NavigationStore.neighbors(at: 1, in: [nil, "b"]) == nil)
  }

  @Test("A workspace moves between its new neighbors at the top level")
  func movesAgent() async {
    let store = NavigationFixture().store
    let ids = [UUID(), UUID(), UUID()]
    let positions = Self.positions(3)
    await store.replace(
      Self.snapshot(zip(ids, positions).map { Self.workspace($0, position: $1) }), machineId: "local",
      requestedAt: Date())
    let order = Self.topLevelIds(store)
    store.moveAgent(order[2], to: 0, among: Array(order.prefix(2)))
    #expect(Self.topLevelIds(store) == [order[2], order[0], order[1]])
  }

  @Test("Nested workspaces sharing a place are spread out, then the moved one lands where it was dropped")
  func movesNestedAgent() async {
    let store = NavigationFixture().store
    let parent = UUID()
    let children = [UUID(), UUID(), UUID()]
    await store.replace(
      Self.snapshot(
        [Self.workspace(parent, position: Self.positions(1)[0])]
          + children.map { Self.workspace($0, parent: parent) }), machineId: "local", requestedAt: Date())
    let nested = { store.agentSidebar.row(id: parent)?.children.map(\.id) ?? [] }
    let order = nested()
    store.moveNestedAgent(order[2], to: 0, among: Array(order.prefix(2)))
    #expect(nested() == [order[2], order[0], order[1]])
  }

  @Test("Folders and projects reorder among their own kind")
  func movesFoldersAndProjects() async {
    let store = NavigationFixture().store
    await store.replace(Self.snapshot([]), machineId: "local", requestedAt: Date())
    let folders = [UUID(), UUID(), UUID()]
    for (index, (id, position)) in zip(folders, Self.positions(3)).enumerated() {
      store.saveFolder(id: id, name: "F\(index)", position: position)
    }
    store.moveFolder(folders[0], to: 2)
    #expect(store.folders.map(\.name) == ["F1", "F2", "F0"])

    let projects = [UUID(), UUID(), UUID()]
    store.moveProject(projects[2], to: 0, among: projects)
    let order = projects.map { store.setting(NavigationStore.projectOrderKeyPrefix + $0.uuidString.lowercased())! }
    #expect(order[2] < order[0] && order[0] < order[1])
  }
}
