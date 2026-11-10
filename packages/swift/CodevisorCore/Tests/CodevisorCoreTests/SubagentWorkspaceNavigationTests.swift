import CodevisorClient
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Subagent workspaces")
struct SubagentWorkspaceNavigationTests {
  let project = Project.fromFolder(URL(fileURLWithPath: "/src/app"), serverId: "m")

  private func workspace(_ chats: ChatSession..., reportedBy serverId: String = "m") -> Workspace {
    Workspace(
      name: "W", rootDirectory: "/src/app", serverId: serverId, projectId: project.id,
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

  @Test("A parent on another machine links when that machine reports the parent's workspace")
  func parentWorkspaceOnAnotherMachine() async {
    let lead = ChatSession(projectId: project.id, serverId: "studio", title: "Lead")
    func child(_ title: String, parent key: String) -> ChatSession {
      ChatSession(projectId: project.id, serverId: "m", title: title, parentSessionId: key, createdBy: .agent)
    }
    let encoded = child("Encoded", parent: "remote2:machine-studio:\(lead.id.uuidString)")
    let legacy = child("Legacy", parent: "remote:machine-studio:\(lead.id.uuidString)")
    let elsewhere = child("Elsewhere", parent: "remote2:machine-other:\(lead.id.uuidString)")
    let bareId = child("Bare", parent: lead.id.uuidString)
    let malformed = child("Malformed", parent: "remote2:machine-studio:\(lead.id.uuidString):extra")
    let children = [encoded, legacy, elsewhere, bareId, malformed]
    let parent = workspace(lead, reportedBy: "machine-studio")
    let childWorkspaces = children.map { workspace($0) }
    let fixture = NavigationFixture()

    await fixture.install(machineId: "studio", projects: [project], sessions: [lead], workspaces: [parent])
    await fixture.install(machineId: "m", projects: [project], sessions: children, workspaces: childWorkspaces)

    let links = Dictionary(
      uniqueKeysWithValues: fixture.store.workspaceEntries.sidebar.map { ($0.id, $0.parent) })
    #expect(childWorkspaces.map { links[$0.id]??.workspaceId } == [parent.id, parent.id, nil, nil, nil])
    #expect(links[childWorkspaces[0].id]??.isAgentMade == true)
  }

  @Test("Percent-encoded machine ids in a remote parent key decode before matching")
  func encodedRemoteParentKey() {
    let sessionId = UUID()

    #expect(
      ParentSessionReference("remote2:machine%3Astudio:\(sessionId.uuidString)")
        == .otherMachine(serverId: "machine:studio", sessionId: sessionId))
    #expect(ParentSessionReference("remote2::\(sessionId.uuidString)") == nil)
    #expect(ParentSessionReference("remote:machine-studio:none") == nil)
    #expect(ParentSessionReference("studio:\(sessionId.uuidString)") == nil)
  }

  @Test("A child's link records whether an agent made it; forks and records without a creator count as the user's")
  func parentLinkRecordsAgentChildren() async {
    let lead = ChatSession(projectId: project.id, serverId: "m", title: "Lead")
    func child(_ title: String, createdBy: SessionCreator?) -> ChatSession {
      ChatSession(
        projectId: project.id, serverId: "m", title: title, parentSessionId: lead.id.uuidString, createdBy: createdBy)
    }
    let spawned = child("Spawned", createdBy: .agent)
    let forked = child("Fork", createdBy: .user)
    let legacy = child("Old", createdBy: nil)
    let workspaces = [workspace(lead), workspace(spawned), workspace(forked), workspace(legacy)]
    let fixture = NavigationFixture()

    await fixture.install(
      machineId: "m", projects: [project], sessions: [lead, spawned, forked, legacy], workspaces: workspaces)

    let agentMade = Dictionary(
      uniqueKeysWithValues: fixture.store.workspaceEntries.sidebar.map { ($0.id, $0.parent?.isAgentMade) })
    #expect(agentMade.count == 4)
    #expect(workspaces.map { agentMade[$0.id] ?? nil } == [nil, true, false, false])
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
    #expect(try decode("{\(base)}").createdBy == nil)
    #expect(try decode(#"{\#(base),"createdBy":"agent"}"#).createdBy == .agent)
    #expect(try decode(#"{\#(base),"createdBy":"automation"}"#).createdBy == .user)
  }
}
