import CodevisorClient
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Subagent workspaces")
struct SubagentWorkspaceNavigationTests {
  let project = Project.fromFolder(URL(fileURLWithPath: "/src/app"), serverId: "m")

  private func workspace(_ chats: ChatSession...) -> Workspace {
    Workspace(
      name: "W", rootDirectory: "/src/app", serverId: "m", projectId: project.id,
      centerTabs: chats.map { WorkspaceTab(root: .leaf(.centerInitial(sessionId: $0.id))) },
      createdAt: Date(timeIntervalSince1970: 0), isServerSynced: true)
  }

  @Test("A workspace's parent is the workspace holding the session that started one of its agents")
  func parentWorkspaceFromSessions() async {
    let lead = ChatSession(projectId: project.id, serverId: "m", title: "Lead")
    let helper = ChatSession(projectId: project.id, serverId: "m", title: "Helper", parentSessionId: lead.id.uuidString)
    let worker = ChatSession(projectId: project.id, serverId: "m", title: "Worker", parentSessionId: lead.id.uuidString)
    let remote = ChatSession(
      projectId: project.id, serverId: "m", title: "Remote", parentSessionId: "remote:studio:\(UUID().uuidString)")
    let orphan = ChatSession(projectId: project.id, serverId: "m", title: "Orphan", parentSessionId: UUID().uuidString)
    let (parent, child, fromRemote, fromGone) = (
      workspace(lead, helper), workspace(worker), workspace(remote), workspace(orphan)
    )
    let fixture = NavigationFixture()

    await fixture.install(
      machineId: "m", projects: [project], sessions: [lead, helper, worker, remote, orphan],
      workspaces: [parent, child, fromRemote, fromGone])

    let parents = Dictionary(
      uniqueKeysWithValues: fixture.store.workspaceEntries.sidebar.map { ($0.id, $0.parentWorkspaceId) })
    #expect(parents == [parent.id: nil, child.id: parent.id, fromRemote.id: nil, fromGone.id: nil])
  }

  @Test("A parent link that arrives later nests the workspace without any workspace change")
  func lateParentLinkNests() async {
    let lead = ChatSession(projectId: project.id, serverId: "m", title: "Lead")
    let worker = ChatSession(projectId: project.id, serverId: "m", title: "Worker")
    let (parent, child) = (workspace(lead), workspace(worker))
    let fixture = NavigationFixture()
    await fixture.install(
      machineId: "m", projects: [project], sessions: [lead, worker], workspaces: [parent, child])

    var linked = serverSession(from: worker)
    linked.workspaceId = child.id.uuidString
    linked.parentSessionId = lead.id.uuidString
    #expect(await fixture.store.apply(.fixture(cursor: 5, sessions: [linked]), machineId: "m"))

    #expect(fixture.store.workspaceEntries.sidebar.first { $0.id == child.id }?.parentWorkspaceId == parent.id)
  }

  @Test("Session records from servers without the field decode with no parent")
  func olderServersHaveNoParent() throws {
    func decode(_ json: String) throws -> ChatSession {
      try JSONDecoder().decode(ServerSession.self, from: Data(json.utf8)).chatSession(serverId: "m")
    }
    let base =
      #""id":"\#(UUID())","projectId":"\#(UUID())","serverId":"s","harnessId":"codex","title":"t","origin":"codevisor","createdAt":"2026-10-27T00:00:00.000Z""#

    #expect(try decode("{\(base)}").parentSessionId == nil)
    #expect(try decode(#"{\#(base),"parentSessionId":"abc"}"#).parentSessionId == "abc")
  }
}
