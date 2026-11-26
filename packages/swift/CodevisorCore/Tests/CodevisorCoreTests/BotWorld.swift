import CodevisorClient
import Foundation
import Testing
import CodevisorTestSupport

@testable import CodevisorCore

@MainActor
struct BotWorld {
  let navigation = NavigationFixture()
  let botProject: Project
  let botChat: ChatSession
  let botWorkspaceId = UUID()
  let bots: BotListModel
  let bot: Bot
  let threads: BotThreadsModel

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
    threads = BotThreadsModel(machines: machines)
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

  func pages(projects: [Project], sessions: [ChatSession]) async throws -> BotPages {
    BotPages(threads: threads, hosts: try await hosts(projects: projects, sessions: sessions, workspaces: []))
  }
}
