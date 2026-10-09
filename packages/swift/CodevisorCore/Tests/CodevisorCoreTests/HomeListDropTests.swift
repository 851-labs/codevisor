import CodevisorClient
import Foundation
import Testing

@testable import CodevisorCore

struct HomeListDropTests {
  private static func row(_ position: String, children: [AgentSidebarRow] = []) -> AgentSidebarRow {
    AgentSidebarRow(
      id: UUID(), title: position, serverId: "local", projectId: UUID(), branch: nil, status: .idle, subagents: [],
      children: children, position: position)
  }

  private static func folder(_ id: String, _ position: String) -> ServerNavigationFolder {
    ServerNavigationFolder(id: id, name: id, position: position, revision: "1")
  }

  /// Folders "a" (holding A1, A2) and "b" (empty), then loose L1 (holding
  /// N1, N2) and L2.
  private let a1 = row("a1")
  private let a2 = row("a2")
  private let n1: AgentSidebarRow
  private let n2: AgentSidebarRow
  private let l1: AgentSidebarRow
  private let l2 = row("l2")

  init() {
    n1 = Self.row("n1")
    n2 = Self.row("n2")
    l1 = Self.row("l1", children: [n1, n2])
  }

  private func model(grouping: AgentSidebarGrouping = .none) -> HomeListModel {
    HomeListModel(
      nodes: [
        .folder(Self.folder("a", "fa"), [a1, a2]), .folder(Self.folder("b", "fb"), []), .agent(l1), .agent(l2),
      ], grouping: grouping)
  }

  @Test("A workspace dropped between a folder's workspaces is filed there, between them")
  func intoFolderBetween() {
    let model = model()
    let folders: [HomeListItem] = [.group("a"), .workspace(a1.id), .workspace(a2.id), .group("b")]
    let drop = HomeListDrop.resolve(.workspace(l2.id), in: .groups, visible: folders, at: 2, model: model)
    #expect(drop == .inGroup("a", after: "a1", before: "a2"))
    // After a folder's last workspace it joins the end of that folder.
    let end = HomeListDrop.resolve(.workspace(l2.id), in: .groups, visible: folders, at: 3, model: model)
    #expect(end == .inGroup("a", after: "a2", before: nil))
  }

  @Test("A workspace can't sit at the top of the Folders list")
  func notAmongFolders() {
    let model = model()
    let folders: [HomeListItem] = [.group("a"), .group("b")]
    #expect(HomeListDrop.resolve(.workspace(l2.id), in: .groups, visible: folders, at: 1, model: model) == nil)
  }

  @Test("Dropped among the loose workspaces it leaves its folder, between its new neighbors")
  func outOfFolder() {
    let model = model()
    let loose: [HomeListItem] = [.workspace(l1.id), .workspace(l2.id)]
    let drop = HomeListDrop.resolve(.workspace(a1.id), in: .workspaces, visible: loose, at: 1, model: model)
    #expect(drop == .loose(after: "l1", before: "l2"))
    // Past an open workspace's nested ones, it's after that workspace.
    let opened: [HomeListItem] = [.workspace(l1.id), .workspace(n1.id), .workspace(n2.id), .workspace(l2.id)]
    let after = HomeListDrop.resolve(.workspace(a1.id), in: .workspaces, visible: opened, at: 3, model: model)
    #expect(after == .loose(after: "l1", before: "l2"))
  }

  @Test("A nested workspace reorders among its siblings, and can't nest under another")
  func nested() {
    let model = model()
    let opened: [HomeListItem] = [.workspace(l1.id), .workspace(n2.id), .workspace(l2.id)]
    let drop = HomeListDrop.resolve(.workspace(n1.id), in: .workspaces, visible: opened, at: 1, model: model)
    #expect(drop == .nested(owner: l1.id, index: 0, siblings: [n2.id]))
    // Past its last sibling it comes out to the loose list.
    let out = HomeListDrop.resolve(.workspace(n1.id), in: .workspaces, visible: opened, at: 2, model: model)
    #expect(out == .loose(after: "l1", before: "l2"))
    let both: [HomeListItem] = [.workspace(l1.id), .workspace(n1.id), .workspace(n2.id)]
    let foreign = HomeListDrop.resolve(.workspace(l2.id), in: .workspaces, visible: both, at: 1, model: model)
    #expect(foreign == nil)
  }

  @Test("A folder moves among the folders, not into a folder's workspaces or the loose list")
  func folders() {
    let model = model()
    let folders: [HomeListItem] = [.group("a"), .workspace(a1.id), .workspace(a2.id)]
    #expect(
      HomeListDrop.resolve(.group("b"), in: .groups, visible: folders, at: 0, model: model)
        == .folder(after: nil, before: "fa"))
    #expect(
      HomeListDrop.resolve(.group("b"), in: .groups, visible: folders, at: 3, model: model)
        == .folder(after: "fa", before: nil))
    #expect(HomeListDrop.resolve(.group("b"), in: .groups, visible: folders, at: 1, model: model) == nil)
    #expect(HomeListDrop.resolve(.group("b"), in: .workspaces, visible: [], at: 0, model: model) == nil)
  }

  @Test("Onto a folder's row, a workspace not already in it is filed there")
  func onto() {
    let model = model()
    #expect(HomeListDrop.onto(.group("b"), dragging: .workspace(l2.id), model: model) == .intoGroup("b"))
    #expect(HomeListDrop.onto(.group("a"), dragging: .workspace(a1.id), model: model) == nil)
    #expect(HomeListDrop.onto(.workspace(l1.id), dragging: .workspace(l2.id), model: model) == nil)
    #expect(HomeListDrop.onto(.group("b"), dragging: .workspace(l2.id), model: self.model(grouping: .project)) == nil)
  }
}
