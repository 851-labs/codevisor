import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Bot sidebar entries")
struct BotSidebarEntryTests {
  @Test("A sub-agent a bot started on another machine sits under that bot, and only that bot")
  func remoteSubAgentsNestUnderTheirBot() async throws {
    let fixture = NavigationFixture()
    let bot = try #require(Bot(serverId: "local", record: .fixture()))
    let repo = Project.fromFolder(URL(fileURLWithPath: "/tmp/laptop-repo"))
    let chats = (0..<2).map { _ in ChatSession(projectId: repo.id, harnessId: "codex") }
    var remoteChild = laptopWorkspace(repo, chats[0])
    remoteChild.botId = bot.id
    remoteChild.botMachineId = "machine-studio"
    var sameIdOnLaptop = laptopWorkspace(repo, chats[1])
    sameIdOnLaptop.botId = bot.id
    for workspace in [remoteChild, sameIdOnLaptop] {
      fixture.store.layouts.setLayout(DeviceLayout(workspace), for: workspace.id)
    }
    let snapshot = ServerNavigationSnapshot.fixture(
      projects: [repo], sessions: chats, workspaces: [remoteChild, sameIdOnLaptop])

    await fixture.store.replace(snapshot, machineId: "laptop", requestedAt: Date())

    let items = try #require(fixture.store.workspaceEntries.botChildren[bot.id])
    let remote = try #require(items.first { $0.id == remoteChild.id })
    let laptopLocal = try #require(items.first { $0.id == sameIdOnLaptop.id })
    #expect(remote.botMachineId == "machine-studio")
    #expect(!remote.belongsToSameMachineBot)
    #expect(laptopLocal.belongsToSameMachineBot)
    #expect(BotSidebarEntry.isChild(remote, of: bot, botServerId: "machine-studio"))
    #expect(!BotSidebarEntry.isChild(remote, of: bot, botServerId: "machine-other"))
    #expect(!BotSidebarEntry.isChild(remote, of: bot, botServerId: nil))
    #expect(!BotSidebarEntry.isChild(laptopLocal, of: bot, botServerId: "machine-studio"))
  }

  @Test("The server's bot machine id survives decoding and the navigation projection")
  func botMachineIdDecodes() throws {
    let record = try JSONDecoder().decode(
      ServerWorkspace.self,
      from: Data(
        #"{"id":"6d1f0c35-2a64-4f3e-9d0a-3b7f3c1c9a10","serverId":"machine-laptop","projectId":"0c6c4c55-0c0e-4b8e-9a53-2a1bb5d1f8d2","name":"n","hasCustomName":false,"isArchived":false,"createdAt":"2026-10-15T00:00:00.000Z","botId":"a8a0d4f4-61c4-4a4e-8b1a-4f2f6e7c9b01","botMachineId":"machine-studio"}"#
          .utf8))

    let workspace = try #require(
      NavigationProjectionBuilder.workspace(from: record, machineId: "laptop", worktreeName: nil))

    #expect(workspace.botMachineId == "machine-studio")
    #expect(workspace.botId == UUID(uuidString: "a8a0d4f4-61c4-4a4e-8b1a-4f2f6e7c9b01"))
  }

  private func laptopWorkspace(_ project: Project, _ chat: ChatSession) -> Workspace {
    Workspace(
      name: project.name, rootDirectory: project.folderURL.path, serverId: "laptop", projectId: project.id,
      centerTabs: [WorkspaceTab(root: .leaf(.centerInitial(sessionId: chat.id)))],
      createdAt: Date(timeIntervalSince1970: 0), isArchived: false, isServerSynced: true)
  }
}
