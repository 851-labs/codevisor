import Foundation
import Testing
import CodevisorTestSupport

@testable import CodevisorCore

@MainActor
@Suite("BotListModel", .timeLimit(.minutes(1)))
struct BotListModelTests {
  private func makeModel(
    features: [String]? = ["bots-v1"],
    bots: [ServerBot] = []
  ) async -> (BotListModel, MachineController, SyncFakeServerClient, NavigationFixture) {
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureInfoFeatures(features)
    fake.setBots(bots)
    let navigation = NavigationFixture()
    let controller = MachineController(
      store: InMemoryStore(),
      projectList: navigation.projectList,
      workspaceSync: navigation.workspaceSync,
      clientFactory: { _ in fake }
    )
    await controller.refreshStatus(for: CodevisorMachine.local.id)
    return (BotListModel(machines: controller), controller, fake, navigation)
  }

  @Test("Bots load from machines that support them and refresh on bot events")
  func loadsAndRefreshesOnEvents() async throws {
    let first = ServerBot.fixture(name: "First")
    let (model, controller, fake, _) = await makeModel(bots: [first])
    controller.onBotsChanged = { serverId in Task { await model.refresh(serverId: serverId) } }

    await model.refresh(serverId: CodevisorMachine.local.id)
    #expect(model.bots.map(\.name) == ["First"])
    let bot = try #require(model.bots.first)
    #expect(model.bot(serverId: CodevisorMachine.local.id, id: bot.id) == bot)
    #expect(model.bot(forSession: bot.sessionId, serverId: CodevisorMachine.local.id) == bot)

    await controller.refreshNavigationState(for: CodevisorMachine.local.id)
    fake.setBots([first, .fixture(name: "Second")])
    fake.emit(kind: "bot.updated", subjectId: first.id)

    await awaitObserved { model.bots.count == 2 }
    #expect(model.bots.map(\.name) == ["First", "Second"])
  }

  @Test("A bot reachable through two machine entries for the same server is listed once")
  func sameServerListsOnce() async throws {
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureInfoFeatures(["bots-v1"])
    fake.setBots([.fixture(name: "Shared")])
    let twin = accountMachine("local-twin")
    let controller = MachineController(
      store: InMemoryStore(),
      projectList: ProjectListModel.fixture(),
      clientFactory: { _ in fake }
    )
    _ = signIn(controller, machines: [twin])
    let model = BotListModel(machines: controller)
    for machineId in [CodevisorMachine.local.id, twin.id] {
      await controller.refreshStatus(for: machineId)
      await model.refresh(serverId: machineId)
    }

    #expect(controller.allMachines.map(\.id) == [CodevisorMachine.local.id, twin.id])
    #expect(model.bots.map(\.serverId) == [CodevisorMachine.local.id])
    #expect(model.botMachines.map(\.id) == [CodevisorMachine.local.id])
  }

  @Test("A machine that does not advertise bots lists none")
  func unsupportedMachineListsNone() async {
    let (model, _, _, _) = await makeModel(features: [], bots: [.fixture()])

    await model.refresh(serverId: CodevisorMachine.local.id)

    #expect(!model.supportsBots(on: CodevisorMachine.local.id))
    #expect(model.bots.isEmpty)
  }

  @Test("Creating a bot returns once its workspace is in navigation")
  func createWaitsForNavigation() async throws {
    let (model, _, fake, navigation) = await makeModel()
    let projectId = UUID()
    let workspaceId = UUID()
    fake.botCreateHandler = { request in
      fake.setProjects([
        ServerProject(
          id: projectId.uuidString,
          name: request.name,
          origin: .codevisor,
          createdAt: "2026-10-15T00:00:00.000Z",
          locations: [],
          isBot: true
        )
      ])
      fake.setWorkspaces([
        ServerWorkspace(
          id: workspaceId.uuidString,
          serverId: "local",
          projectId: projectId.uuidString,
          name: request.name,
          hasCustomName: false,
          rootDirectory: "/tmp/codevisor/bots/helper",
          isArchived: false,
          archivedAt: nil,
          createdAt: "2026-10-15T00:00:00.000Z",
          updatedAt: nil
        )
      ])
      return .fixture(name: request.name, projectId: projectId, workspaceId: workspaceId)
    }

    let bot = try await model.create(
      ServerCreateBotRequest(name: "Helper", symbolName: "ant", harnessId: "codex", projectIds: ["p"]),
      on: CodevisorMachine.local.id
    )

    #expect(bot.workspaceId == workspaceId)
    #expect(navigation.store.workspaceEntries.entry(workspaceId).workspace != nil)
    #expect(model.bots.map(\.id) == [bot.id])
  }
}
