import CodevisorClient
import Foundation
import Testing
import CodevisorTestSupport

@testable import CodevisorCore

@MainActor
@Suite("Chat hosts", .timeLimit(.minutes(1)))
struct ChatHostsTests {
  let botProject = Project.fromFolder(URL(fileURLWithPath: "/bots/helper"), serverId: "local")
  let appProject = Project.fromFolder(URL(fileURLWithPath: "/src/app"), serverId: "local")
  let toolsProject = Project.fromFolder(URL(fileURLWithPath: "/src/tools"), serverId: "local")

  @Test("A bot's sub-agents, at any depth and in any project, open inside the bot")
  func botSubagentsOpenInTheBot() async throws {
    let world = try await World(botProject: botProject)
    let agent = world.chat("Christmas list", in: appProject, createdBy: world.botChat)
    let helper = world.chat("Price checker", in: appProject, createdBy: agent)
    let hosts = try await world.hosts(
      projects: [appProject], sessions: [agent, helper], workspaces: [world.workspace(agent, in: appProject)])

    #expect(hosts.host(of: agent) == .bot(world.bot))
    #expect(hosts.host(of: helper) == .bot(world.bot))
  }

  @Test("A chat left in a bot's layout is never a guest there")
  func botWorkspaceNeverHostsGuests() async throws {
    let world = try await World(botProject: botProject)
    let stray = world.chat("Stray", in: appProject)
    let hosts = try await world.hosts(
      projects: [appProject], sessions: [stray], workspaces: [world.botWorkspace(alsoShowing: stray)])

    #expect(hosts.host(of: stray) == .own)
  }

  @Test("An ordinary agent's sub-agent from another project is a guest in that agent's workspace")
  func ordinaryAgentHostsItsSubagents() async throws {
    let world = try await World(botProject: botProject)
    let lead = world.chat("Lead", in: toolsProject)
    let helper = world.chat("Helper", in: appProject, createdBy: lead)
    let leadWorkspace = world.workspace(lead, in: toolsProject)
    let hosts = try await world.hosts(
      projects: [appProject, toolsProject], sessions: [lead, helper], workspaces: [leadWorkspace])

    #expect(hosts.host(of: lead) == .own)
    guard case let .guest(host) = hosts.host(of: helper) else {
      Issue.record("Expected the helper to be a guest")
      return
    }
    #expect(host.id == leadWorkspace.id)
  }
}

@MainActor
private struct World {
  let navigation = NavigationFixture()
  let botProject: Project
  let botChat: ChatSession
  let botWorkspaceId = UUID()
  let bots: BotListModel
  let bot: Bot

  init(botProject: Project) async throws {
    self.botProject = botProject
    let botChat = ChatSession(projectId: botProject.id, serverId: "local", title: "Helper")
    self.botChat = botChat
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureInfoFeatures(["bots-v1"])
    fake.setBots([
      .fixture(projectId: botProject.id, sessionId: botChat.id, workspaceId: botWorkspaceId)
    ])
    let machines = MachineController(
      store: InMemoryStore(), projectList: navigation.projectList, workspaceSync: navigation.workspaceSync,
      clientFactory: { _ in fake })
    await machines.refreshStatus(for: CodevisorMachine.local.id)
    bots = BotListModel(machines: machines)
    await bots.refresh(serverId: CodevisorMachine.local.id)
    bot = try #require(bots.bots.first)
  }

  func chat(_ title: String, in project: Project, createdBy creator: ChatSession? = nil) -> ChatSession {
    ChatSession(
      projectId: project.id, serverId: "local", title: title, createdBy: creator == nil ? nil : .agent,
      createdByAgent: creator.map { AgentReference(agentId: $0.id, machineId: "local") })
  }

  func workspace(_ chat: ChatSession, in project: Project) -> Workspace {
    Workspace(
      name: chat.title, rootDirectory: project.folderURL.path, serverId: "local", projectId: project.id,
      centerTree: .leaf(.centerInitial(sessionId: chat.id)), isServerSynced: true)
  }

  func botWorkspace(alsoShowing others: ChatSession...) -> Workspace {
    Workspace(
      id: botWorkspaceId, name: "Helper", rootDirectory: botProject.folderURL.path, serverId: "local",
      projectId: botProject.id,
      centerTabs: ([botChat] + others).map { WorkspaceTab(root: .leaf(.centerInitial(sessionId: $0.id))) },
      isServerSynced: true)
  }

  func hosts(projects: [Project], sessions: [ChatSession], workspaces: [Workspace]) async throws -> ChatHosts {
    let ownsBotWorkspace = workspaces.contains { $0.id == botWorkspaceId }
    await navigation.install(
      projects: [botProject] + projects, sessions: [botChat] + sessions,
      workspaces: (ownsBotWorkspace ? [] : [botWorkspace()]) + workspaces)
    return ChatHosts(projectList: navigation.projectList, bots: bots, workspaces: navigation.workspaces)
  }
}
