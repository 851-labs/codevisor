import CodevisorClient
import Foundation
import Testing

@testable import CodevisorCore

struct AgentSidebarTests {
  private let project = Project(id: UUID(), serverId: "local", name: "codevisor")
  private let created = Date(timeIntervalSince1970: 1_000)

  private func workspace(_ name: String, parent: Workspace? = nil, at position: String? = nil) -> Workspace {
    var workspace = make(name, projectId: project.id)
    workspace.parentWorkspaceId = parent?.id
    workspace.parentTabPosition = parent == nil ? nil : "0000000000018"
    workspace.sidebarPosition = position
    return workspace
  }

  private func make(_ name: String, projectId: UUID) -> Workspace {
    Workspace(
      name: name, rootDirectory: nil, serverId: "local", projectId: projectId,
      centerTabs: [WorkspaceTab(root: .leaf(PaneGroupState()))], createdAt: created, isServerSynced: true)
  }

  private func chat(
    _ title: String, parent: ChatSession? = nil, state: SessionSidebarState = .idle, offset: TimeInterval = 0
  ) -> ChatSession {
    var session = ChatSession(
      projectId: project.id, title: title, createdAt: created.addingTimeInterval(offset), sidebarState: state)
    session.parentSessionId = parent?.id
    return session
  }

  private func build(
    _ workspaces: [Workspace], _ placed: [(ChatSession, Workspace)], records: ServerNavigationRecords = .init(),
    grouping: AgentSidebarGrouping = .none, projects: [Project]? = nil
  ) -> [AgentSidebarNode] {
    AgentSidebar.build(
      workspaces: workspaces, sessions: placed.map(\.0),
      sessionIndex: Dictionary(uniqueKeysWithValues: placed.map { ($0.0.id, $0.1.id) }),
      projects: projects ?? [project], records: records, grouping: grouping)
  }

  @Test("Subagents nest one level under their root, deeper ones flattened with who made them")
  func nesting() throws {
    let orchestrator = workspace("orchestrator")
    let owned = workspace("write tests", parent: orchestrator)
    let nested = workspace("migrate schema", parent: owned)
    let root = chat("Refactor sync")
    let shared = chat("review", parent: root, state: .inProgress, offset: 1)
    let helper = chat("lint", parent: shared, state: .waitingForUser, offset: 2)
    let ownedRoot = chat("write tests", parent: root, state: .inProgress)
    let nestedRoot = chat("migrate schema", parent: ownedRoot, state: .errored)
    let nodes = build(
      [orchestrator, owned, nested],
      [(root, orchestrator), (shared, orchestrator), (helper, orchestrator), (ownedRoot, owned), (nestedRoot, nested)])

    #expect(nodes.count == 1)
    guard case let .agent(row) = try #require(nodes.first) else { Issue.record("expected an agent"); return }
    // Named after its own chat: the workspace was never renamed.
    #expect(row.title == "Refactor sync")
    #expect(row.subagents.map(\.title) == ["review", "lint", "write tests", "migrate schema"])
    #expect(row.subagents.map(\.kind) == [.chat, .chat, .workspace, .workspace])
    #expect(row.subagents.map(\.via) == [nil, "review", nil, "write tests"])
    #expect(row.rollup == AgentRollup(finished: 0, total: 4, status: .errored))
    // Agents with workspaces of their own nest under their owner, recursively.
    #expect(row.children.map(\.title) == ["write tests"])
    #expect(row.children.first?.children.map(\.title) == ["migrate schema"])
    #expect(row.children.first?.children.first?.children.isEmpty == true)
  }

  @Test("Folders and loose agents share one order; a folder that is gone leaves its agents loose")
  func manualGrouping() {
    let first = workspace("first", at: "0000000000011")
    let filed = workspace("filed", at: "0000000000013")
    var orphaned = workspace("orphaned", at: "0000000000014")
    let folder = ServerNavigationFolder(
      id: UUID().uuidString.lowercased(), name: "Payments", position: "0000000000012",
      revision: "0000000000001-000000-a")
    var filedIntoFolder = filed
    filedIntoFolder.folderId = UUID(uuidString: folder.id)
    orphaned.folderId = UUID()
    let deleted = ServerNavigationFolder(
      id: UUID().uuidString, name: "Old", position: "0", deleted: true, revision: "0000000000001-000000-a")
    let nodes = build([first, filedIntoFolder, orphaned], [], records: .init(folders: [folder, deleted]))
    #expect(nodes.map(\.id) == ["agent:\(first.id)", "folder:\(folder.id)", "agent:\(orphaned.id)"])
    if case let .folder(_, rows) = nodes[1] { #expect(rows.map(\.title) == ["filed"]) }
  }

  @Test("Projects come in the synced project order, then by name")
  func projectGrouping() {
    let other = Project(id: UUID(), serverId: "local", name: "another")
    let elsewhere = make("elsewhere", projectId: other.id)
    let here = workspace("here")
    let unordered = build([here, elsewhere], [], grouping: .project, projects: [project, other])
    #expect(unordered.map(\.id) == ["project:local:\(other.id)", "project:local:\(project.id)"])
    let order = ServerNavigationRecords(settings: [
      .init(
        key: NavigationStore.projectOrderKeyPrefix + project.id.uuidString.lowercased(), value: "1",
        revision: "0000000000001-000000-a")
    ])
    let ordered = build([here, elsewhere], [], records: order, grouping: .project, projects: [project, other])
    #expect(ordered.map(\.id) == ["project:local:\(project.id)", "project:local:\(other.id)"])
  }

  @Test("Archived subagents leave, and an owner's archive frees nothing it still shows")
  func archived() {
    let orchestrator = workspace("orchestrator")
    var owned = workspace("done", parent: orchestrator)
    owned.isArchived = true
    var released = workspace("released", parent: orchestrator)
    var archivedOwner = orchestrator
    archivedOwner.isArchived = true
    released.parentWorkspaceId = archivedOwner.id
    let nodes = build([archivedOwner, owned, released], [])
    // The owner is archived, so its live subagent stands alone.
    #expect(nodes.map(\.id) == ["agent:\(released.id)"])
  }
}
