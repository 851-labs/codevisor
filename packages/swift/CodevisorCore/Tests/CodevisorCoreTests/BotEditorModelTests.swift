import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("BotEditorModel")
struct BotEditorModelTests {
  @Test("Editing a bot starts from its name and icon and only needs a name to save")
  func editingNeedsOnlyAName() throws {
    let environment = AppEnvironment.preview(seedProjects: [], seedSessions: [])
    let bot = try #require(Bot(serverId: CodevisorMachine.local.id, record: .fixture(name: "Helper")))
    let editor = BotEditorModel(target: .edit(bot), environment: environment)

    #expect(editor.name == "Helper")
    #expect(editor.symbolName == bot.symbolName)
    #expect(editor.canSave)
    editor.name = "   "
    #expect(!editor.canSave)
  }

  @Test("A new bot keeps each chosen project once and drops them when its machine changes")
  func creatingTracksProjectsPerMachine() async {
    let environment = AppEnvironment.preview(seedProjects: [], seedSessions: [])
    let editor = BotEditorModel(target: .create, environment: environment)
    let project = UUID()

    editor.name = "Helper"
    await editor.addProject(project)
    await editor.addProject(project)
    #expect(editor.projectIds == [project])
    #expect(!editor.canSave)

    editor.serverId = "another-machine"
    #expect(editor.projectIds.isEmpty)
  }

  private func editedBot(
    features: [String],
    projectIds: [UUID]
  ) async throws -> (BotEditorModel, SyncFakeServerClient) {
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureInfoFeatures(features)
    fake.setBots([.fixture(projectIds: projectIds)])
    let environment = AppEnvironment(
      configCache: ConfigOptionCache(store: InMemoryStore()),
      settings: AppSettingsModel(store: InMemoryStore()),
      machineStore: InMemoryStore(),
      harnessService: PreviewHarnessService(),
      machineClientFactory: { _ in fake }
    )
    await environment.machines.refreshStatus(for: CodevisorMachine.local.id)
    await environment.bots.refresh(serverId: CodevisorMachine.local.id)
    let bot = try #require(environment.bots.bots.first)
    return (BotEditorModel(target: .edit(bot), environment: environment), fake)
  }

  @Test("Editing a bot adds and removes projects on its machine right away but keeps the last one")
  func editingChangesProjectsOnTheMachine() async throws {
    let first = UUID()
    let second = UUID()
    let (editor, fake) = try await editedBot(features: ["bots-v1", "bot-projects-v1"], projectIds: [first])
    #expect(!editor.canRemoveProject(first))

    await editor.addProject(second)
    #expect(editor.projectIds == [first, second])
    #expect(try await fake.listBots().first?.projects.count == 2)
    await editor.removeProject(first)
    #expect(editor.projectIds == [second])
    await editor.removeProject(second)
    #expect(editor.projectIds == [second])

    fake.botProjectError = CodevisorServerClientError.invalidResponse
    await editor.addProject(first)
    #expect(editor.projectIds == [second])
    #expect(editor.errorMessage != nil)
    #expect(editor.changingProjectIds.isEmpty)
  }

  @Test("A machine without project changes keeps an existing bot's projects as they are")
  func olderMachinesKeepProjects() async throws {
    let project = UUID()
    let (editor, fake) = try await editedBot(features: ["bots-v1"], projectIds: [project])

    await editor.addProject(UUID())

    #expect(!editor.canChangeProjects)
    #expect(editor.projectIds == [project])
    #expect(try await fake.listBots().first?.projects.count == 1)
  }
}
