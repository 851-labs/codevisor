import ACPKit
import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("BotEditorModel")
struct BotEditorModelTests {
  private static let crowned = ServerBotMascot(color: "sky", hat: "crown", eyewear: "none")
  private static let options = ServerBotMascotOptions(
    colors: [.init(id: "sky", title: "Sky", gradient: ["#D3EEFF", "#7DC2F5"])],
    hats: [.init(id: "none", title: "None"), .init(id: "crown", title: "Crown")],
    eyewear: [.init(id: "none", title: "None")],
    nextBotMascot: ServerBotMascot(color: "lilac", hat: "none", eyewear: "none")
  )

  @Test("Editing a bot starts from its name and mascot and only needs a name to save")
  func editingNeedsOnlyAName() throws {
    let environment = AppEnvironment.preview(seedProjects: [], seedSessions: [])
    let bot = try #require(
      Bot(serverId: CodevisorMachine.local.id, record: .fixture(name: "Helper", mascot: Self.crowned)))
    let editor = BotEditorModel(target: .edit(bot), environment: environment)

    #expect(editor.name == "Helper")
    #expect(editor.mascot == Self.crowned)
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

  @Test("Add Project lists the composer's git projects not yet on the bot, wherever they live, in one list")
  func addProjectListsComposerProjects() async {
    let shared = checkout("app", on: [CodevisorMachine.local.id, "remote-b"])
    let elsewhere = checkout("api", on: ["remote-b"])
    let plainFolder = checkout("notes", on: ["remote-c"], isGit: false)
    let environment = AppEnvironment.preview(seedProjects: shared + elsewhere + plainFolder, seedSessions: [])
    let editor = BotEditorModel(target: .create, environment: environment)
    editor.serverId = CodevisorMachine.local.id
    let composerOrder = environment.projectList.fleetActiveProjectGroupsByWorkspaceRecency([]).map(\.name)

    #expect(editor.addableProjectGroups.map(\.name) == composerOrder.filter { ["app", "api"].contains($0) })

    let app = editor.addableProjectGroups.first { $0.name == "app" }
    if let app { await editor.addProject(from: app) }
    #expect(editor.projectIds == [shared[0].id])
    #expect(editor.addableProjectGroups.map(\.name) == ["api"])
  }

  private func checkout(_ name: String, on serverIds: [String], isGit: Bool = true) -> [Project] {
    serverIds.map { serverId in
      let id = UUID()
      return Project(
        id: id, serverId: serverId, name: name,
        locations: [
          ProjectLocation(projectId: id, serverId: serverId, folderPath: "/src/\(name)", isGitRepository: isGit)
        ],
        repoUrl: "git@github.com:acme/\(name).git", repoKey: "github.com/acme/\(name)")
    }
  }

  @Test("A new bot starts from the machine's next mascot, and an edited bot saves the one picked")
  func mascotComesFromTheMachine() async throws {
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.botMascotOptionsResult = Self.options
    let creator = BotEditorModel(target: .create, environment: makeEnvironment(fake))
    let (editor, editedFake) = try await editedBot(features: ["bots-v1"], projectIds: [], mascot: Self.crowned)
    editedFake.botMascotOptionsResult = Self.options

    await creator.loadMascotOptions()
    await editor.loadMascotOptions()
    #expect(creator.mascot == Self.options.nextBotMascot)
    #expect(editor.mascot == Self.crowned)
    #expect(editor.mascotOptions == Self.options)

    editor.mascot?.hat = "none"
    #expect(await editor.save())
    #expect(try await editedFake.listBots().first?.mascot?.hat == "none")
  }

  @Test("Mascot options keep loading until the machine answers, so Edit Mascot appears after a hiccup")
  func mascotOptionsRetryUntilTheMachineAnswers() async {
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    let clock = TestClock()
    let editor = BotEditorModel(
      target: .create, environment: makeEnvironment(fake), retryPolicy: RetryPolicy(clock: clock, jitter: 0))

    let load = Task { await editor.loadMascotOptions() }
    await clock.waitForSleep(.seconds(1))
    #expect(editor.mascotOptions == nil)

    fake.botMascotOptionsResult = Self.options
    clock.advance(by: .seconds(1))
    await load.value

    #expect(editor.mascotOptions == Self.options)
    #expect(editor.mascot == Self.options.nextBotMascot)
  }

  private func makeEnvironment(_ fake: SyncFakeServerClient) -> AppEnvironment {
    AppEnvironment(
      configCache: ConfigOptionCache(store: InMemoryStore()),
      settings: AppSettingsModel(store: InMemoryStore()),
      machineStore: InMemoryStore(),
      harnessService: PreviewHarnessService(),
      machineClientFactory: { _ in fake }
    )
  }

  private func editedBot(
    features: [String],
    projectIds: [UUID],
    mascot: ServerBotMascot? = nil
  ) async throws -> (BotEditorModel, SyncFakeServerClient) {
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureInfoFeatures(features)
    fake.setBots([.fixture(projectIds: projectIds, mascot: mascot)])
    let environment = makeEnvironment(fake)
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

  @Test("A new project joins the bot when its machine says it is a git repo, before the local list catches up")
  func newProjectsTrustTheMachine() async throws {
    let (editor, fake) = try await editedBot(features: ["bots-v1", "bot-projects-v1"], projectIds: [UUID()])
    let cloned = localFolder("cloned")
    let plain = localFolder("plain")
    fake.setProjects([serverProject(cloned, isGit: false), serverProject(plain, isGit: false)])
    fake.listedProjects = [serverProject(cloned, isGit: true), serverProject(plain, isGit: false)]

    await editor.addNewProject(cloned)
    #expect(editor.projectIds.contains(cloned.id))
    #expect(editor.errorMessage == nil)

    await editor.addNewProject(plain)
    #expect(!editor.projectIds.contains(plain.id))
    #expect(editor.errorMessage == "plain isn't a git repository, so a bot can't use it.")
  }

  private func localFolder(_ name: String) -> Project {
    Project.fromFolder(URL(fileURLWithPath: "/src/\(name)"), serverId: CodevisorMachine.local.id)
  }

  private func serverProject(_ project: Project, isGit: Bool) -> ServerProject {
    let createdAt = "2026-11-02T12:00:00.000Z"
    return ServerProject(
      id: project.id.uuidString, name: project.name, origin: .codevisor, createdAt: createdAt,
      locations: [
        ServerProjectLocation(
          id: UUID().uuidString, projectId: project.id.uuidString, serverId: project.serverId,
          folderPath: project.folderURL.path, createdAt: createdAt, isGitRepository: isGit)
      ])
  }

  @Test("A new bot on a machine that allows project-less bots skips projects and saves without one")
  func projectlessMachinesCreateWithoutProjects() async {
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureInfoFeatures(["bots-v1", "bot-projects-v1", "bot-projectless-v1"])
    fake.capabilitiesHandler = { _ in ServerCapabilities(harnesses: [Self.readyHarness]) }
    let environment = makeEnvironment(fake)
    await environment.machines.refreshStatus(for: CodevisorMachine.local.id)
    let editor = BotEditorModel(target: .create, environment: environment)
    editor.serverId = CodevisorMachine.local.id
    editor.name = "Helper"

    await editor.loadModels()

    #expect(!editor.showsProjects)
    #expect(editor.projectIds.isEmpty)
    #expect(editor.canSave)
  }

  @Test("A new bot on an older machine still asks for a project before it can save")
  func olderMachinesNeedAProjectToCreate() async {
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureInfoFeatures(["bots-v1", "bot-projects-v1"])
    fake.capabilitiesHandler = { _ in ServerCapabilities(harnesses: [Self.readyHarness]) }
    let environment = makeEnvironment(fake)
    await environment.machines.refreshStatus(for: CodevisorMachine.local.id)
    let editor = BotEditorModel(target: .create, environment: environment)
    editor.serverId = CodevisorMachine.local.id
    editor.name = "Helper"

    await editor.loadModels()

    #expect(editor.showsProjects)
    #expect(!editor.canSave)
  }

  @Test("Editing a bot on a machine that allows project-less bots can remove its last project")
  func projectlessMachinesDropTheLastProject() async throws {
    let project = UUID()
    let (editor, fake) = try await editedBot(
      features: ["bots-v1", "bot-projects-v1", "bot-projectless-v1"], projectIds: [project])

    #expect(editor.showsProjects)
    #expect(editor.canRemoveProject(project))
    await editor.removeProject(project)

    #expect(editor.projectIds.isEmpty)
    #expect(try await fake.listBots().first?.projects.isEmpty == true)
  }

  nonisolated private static let readyHarness = ServerHarnessCapability(
    harness: ServerHarness(
      id: "codex", name: "Codex", symbolName: "sparkle", source: "registry", launchKind: "executable",
      enabled: true, readiness: ServerHarnessReadiness(state: "ready", detail: nil)),
    modes: nil,
    configOptions: [
      SessionConfigOption(
        id: "model", name: "Model", category: SessionConfigOption.Category.model, currentValue: "gpt-5",
        options: [SessionConfigSelectOption(value: "gpt-5", name: "GPT-5")])
    ]
  )

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
