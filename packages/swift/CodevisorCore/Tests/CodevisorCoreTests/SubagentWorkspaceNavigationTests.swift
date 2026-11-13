import CodevisorClient
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Subagent workspaces")
struct SubagentWorkspaceNavigationTests {
  let project = Project.fromFolder(URL(fileURLWithPath: "/src/app"), serverId: "m")
  let laptopProject = Project.fromFolder(URL(fileURLWithPath: "/src/app"), serverId: "laptop")

  private func workspace(_ chats: ChatSession..., on machine: String = "m") -> Workspace {
    Workspace(
      name: "W", rootDirectory: "/src/app", serverId: machine,
      projectId: machine == "m" ? project.id : laptopProject.id,
      centerTabs: chats.map { WorkspaceTab(root: .leaf(.centerInitial(sessionId: $0.id))) },
      createdAt: Date(timeIntervalSince1970: 0), isServerSynced: true)
  }

  private func chat(
    _ title: String, on machine: String = "m", createdBy creator: ChatSession? = nil, creatorMachine: String = "m"
  ) -> ChatSession {
    ChatSession(
      projectId: machine == "m" ? project.id : laptopProject.id, serverId: machine, title: title,
      createdBy: creator == nil ? nil : .agent,
      createdByAgent: creator.map { AgentReference(agentId: $0.id, machineId: creatorMachine) })
  }

  @Test("A workspace's parent is the workspace of the agent that created it, on whichever server that agent runs")
  func parentWorkspaceFromCreators() async {
    let lead = chat("Lead")
    let helper = chat("Helper", createdBy: lead)
    let worker = chat("Worker", createdBy: lead)
    let onLaptop = chat("On laptop", on: "laptop", createdBy: lead)
    let wrongMachine = chat("Wrong machine", on: "laptop", createdBy: lead, creatorMachine: "laptop")
    let orphan = chat("Orphan", createdBy: chat("Gone"))
    let (parent, child, laptopChild, misattributed, fromGone) = (
      workspace(lead, helper), workspace(worker), workspace(onLaptop, on: "laptop"),
      workspace(wrongMachine, on: "laptop"), workspace(orphan)
    )
    let fixture = NavigationFixture()

    await fixture.install(
      machineId: "studio-in-app", projects: [project], sessions: [lead, helper, worker, orphan],
      workspaces: [parent, child, fromGone])
    await fixture.install(
      machineId: "laptop-in-app", projects: [laptopProject], sessions: [onLaptop, wrongMachine],
      workspaces: [laptopChild, misattributed])

    let parents = Dictionary(
      uniqueKeysWithValues: fixture.store.workspaceEntries.sidebar.map { ($0.id, $0.parentWorkspaceId) })
    #expect(
      parents == [
        parent.id: nil, child.id: parent.id, laptopChild.id: parent.id, misattributed.id: nil, fromGone.id: nil,
      ])
  }

  @Test("An agent that stands alone has no parent, though the agent that started it is known")
  func standaloneAgentHasNoParent() async {
    let lead = chat("Lead")
    let worker = chat("Worker", createdBy: lead)
    var standalone = chat("Standalone", createdBy: lead)
    standalone.isDetached = true
    let (parent, child, own) = (workspace(lead), workspace(worker), workspace(standalone))
    let fixture = NavigationFixture()

    await fixture.install(
      machineId: "m", projects: [project], sessions: [lead, worker, standalone],
      workspaces: [parent, child, own])

    let parents = Dictionary(
      uniqueKeysWithValues: fixture.store.workspaceEntries.sidebar.map { ($0.id, $0.parentWorkspaceId) })
    #expect(parents == [parent.id: nil, child.id: parent.id, own.id: nil])
    #expect(fixture.store.projection.sessions.first { $0.id == standalone.id }?.createdByAgent?.agentId == lead.id)
  }

  @Test("A chat with no workspace belongs in the workspace of the agent that owns it")
  func ownedChatUsesOwnersWorkspace() async {
    let lead = chat("Lead")
    let loose = chat("Loose", createdBy: lead)
    let looseChild = chat("Loose child", createdBy: loose)
    var archived = chat("Archived", createdBy: lead)
    archived.isArchived = true
    var standalone = chat("Standalone", createdBy: lead)
    standalone.isDetached = true
    let parent = workspace(lead)
    let fixture = NavigationFixture()

    await fixture.install(
      machineId: "m", projects: [project], sessions: [lead, loose, looseChild, archived, standalone],
      workspaces: [parent])

    let list = fixture.projectList
    #expect(list.owningWorkspaceId(of: loose) == parent.id)
    #expect(list.owningWorkspaceId(of: looseChild) == parent.id)
    #expect(list.owningWorkspaceId(of: standalone) == nil)
    #expect(list.owningWorkspaceId(of: lead) == nil)
    #expect(list.chats(ownedBy: [lead.id]).map(\.title) == ["Loose"])
  }

  @Test("A bot's workspace is known from its project, before any bot list has loaded")
  func botHomeKnownFromProject() async {
    let botHome = Project.fromFolder(URL(fileURLWithPath: "/tmp/codevisor/bots/helper"), serverId: "m")
    let lead = chat("Lead")
    let bot = ChatSession(projectId: botHome.id, serverId: "m", title: "Helper")
    let home = Workspace(
      name: "Helper", rootDirectory: nil, serverId: "m", projectId: botHome.id,
      centerTabs: [WorkspaceTab(root: .leaf(.centerInitial(sessionId: bot.id)))],
      createdAt: Date(timeIntervalSince1970: 0), isServerSynced: true)
    let ordinary = workspace(lead)
    let fixture = NavigationFixture()
    for workspace in [ordinary, home] {
      fixture.store.layouts.setLayout(DeviceLayout(workspace), for: workspace.id)
    }
    var snapshot = ServerNavigationSnapshot.fixture(
      projects: [project, botHome], sessions: [lead, bot], workspaces: [ordinary, home])

    await fixture.store.replace(snapshot, machineId: "m", requestedAt: Date())
    #expect(fixture.store.workspaceEntries.botHomeIds.isEmpty)

    snapshot.projects = snapshot.projects.map { record in
      var record = record
      record.isBot = record.id == botHome.id.uuidString
      return record
    }
    await fixture.store.replace(snapshot, machineId: "m", requestedAt: Date())

    #expect(fixture.store.workspaceEntries.botHomeIds == [home.id])
    #expect(fixture.store.workspaceEntries.sidebar.filter { !$0.isBotHome }.map(\.id) == [ordinary.id])
  }

  @Test("Agent-made children are quiet, a bot's included; forks are not")
  func quietChildren() async {
    let botHome = Project.fromFolder(URL(fileURLWithPath: "/tmp/codevisor/bots/helper"), serverId: "m")
    let lead = chat("Lead")
    let bot = ChatSession(projectId: botHome.id, serverId: "m", title: "Helper")
    let spawned = chat("Spawned", createdBy: lead)
    let fromBot = chat("From bot", createdBy: bot)
    var forked = chat("Fork")
    forked.forkedFromAgent = AgentReference(agentId: lead.id, machineId: "m")
    let home = Workspace(
      name: "Helper", rootDirectory: nil, serverId: "m", projectId: botHome.id,
      centerTabs: [WorkspaceTab(root: .leaf(.centerInitial(sessionId: bot.id)))],
      createdAt: Date(timeIntervalSince1970: 0), isServerSynced: true)
    let workspaces = [workspace(lead), workspace(spawned), workspace(forked), workspace(fromBot), home]
    let fixture = NavigationFixture()
    for workspace in workspaces {
      fixture.store.layouts.setLayout(DeviceLayout(workspace), for: workspace.id)
    }
    var snapshot = ServerNavigationSnapshot.fixture(
      projects: [project, botHome], sessions: [lead, bot, spawned, forked, fromBot], workspaces: workspaces)
    snapshot.projects = snapshot.projects.map { record in
      var record = record
      record.isBot = record.id == botHome.id.uuidString
      return record
    }

    await fixture.store.replace(snapshot, machineId: "m", requestedAt: Date())

    let links = Dictionary(
      uniqueKeysWithValues: fixture.store.workspaceEntries.sidebar.map { ($0.id, $0.parent) })
    #expect(workspaces.prefix(4).map { links[$0.id]??.isQuiet } == [nil, true, false, true])
    #expect(links[workspaces[3].id]??.workspaceId == home.id)
  }

  @Test("A creator that arrives later nests the workspace without any workspace change")
  func lateCreatorNests() async {
    let lead = chat("Lead")
    let worker = chat("Worker")
    let (parent, child) = (workspace(lead), workspace(worker))
    let fixture = NavigationFixture()
    await fixture.install(
      machineId: "m", projects: [project], sessions: [lead, worker], workspaces: [parent, child])

    var linked = serverSession(from: worker)
    linked.workspaceId = child.id.uuidString
    linked.createdByAgentId = lead.id.uuidString
    linked.createdByAgentMachineId = "m"
    #expect(await fixture.store.apply(.fixture(cursor: 5, sessions: [linked]), machineId: "m"))

    #expect(fixture.store.workspaceEntries.sidebar.first { $0.id == child.id }?.parentWorkspaceId == parent.id)
  }

  @Test("Session records name their creator and fork source only when both the agent and its machine are set")
  func agentReferencesDecode() throws {
    func decode(_ json: String) throws -> ChatSession {
      try JSONDecoder().decode(ServerSession.self, from: Data(json.utf8)).chatSession(serverId: "m")
    }
    let creator = UUID()
    let base =
      #""id":"\#(UUID())","projectId":"\#(UUID())","serverId":"s","harnessId":"codex","title":"t","origin":"codevisor","createdAt":"2026-10-27T00:00:00.000Z""#

    #expect(try decode("{\(base)}").createdByAgent == nil)
    #expect(
      try decode(#"{\#(base),"createdByAgentId":"\#(creator)","createdByAgentMachineId":"studio"}"#).createdByAgent
        == AgentReference(agentId: creator, machineId: "studio"))
    #expect(try decode(#"{\#(base),"createdByAgentId":"\#(creator)"}"#).createdByAgent == nil)
    #expect(
      try decode(#"{\#(base),"forkedFromAgentId":"\#(creator)","forkedFromAgentMachineId":"s"}"#).forkedFromAgent
        == AgentReference(agentId: creator, machineId: "s"))
    #expect(try decode(#"{\#(base),"createdBy":"automation"}"#).createdBy == .user)
  }
}
