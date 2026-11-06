import Foundation
import Observation

@MainActor
@Observable
public final class BotEditorModel {
  public let target: BotEditorTarget
  public var name: String
  public var mascot: ServerBotMascot?
  public var serverId: String {
    didSet { if serverId != oldValue { draftProjectIds = [] } }
  }
  public var mode = BotMode.conversation
  public private(set) var models: BotModelSelection?
  public private(set) var mascotOptions: ServerBotMascotOptions?
  public private(set) var isSaving = false
  public private(set) var didSave = false
  public private(set) var createdBot: Bot?
  public private(set) var errorMessage: String?
  public private(set) var changingProjectIds: Set<UUID> = []
  public let projectSetup: BotProjectSetup
  private var draftProjectIds: [UUID] = []
  private var addingProjectIds: [UUID] = []
  @ObservationIgnored private let environment: AppEnvironment
  @ObservationIgnored private let botId = UUID()
  @ObservationIgnored private let retryPolicy: RetryPolicy

  public init(target: BotEditorTarget, environment: AppEnvironment, retryPolicy: RetryPolicy = .standard) {
    self.target = target
    self.environment = environment
    self.retryPolicy = retryPolicy
    projectSetup = BotProjectSetup(environment: environment)
    switch target {
    case .create:
      name = ""
      serverId = environment.defaultBotServerId
    case let .edit(bot):
      name = bot.name
      mascot = bot.mascot
      serverId = bot.serverId
      mode = bot.mode
    }
  }

  public var editedBot: Bot? {
    if case let .edit(bot) = target { return bot }
    return nil
  }

  public var symbolName: String {
    editedBot?.symbolName ?? BotIcon.fallback.systemImage
  }

  public var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public var machines: [CodevisorMachine] {
    environment.bots.botMachines
  }

  public var machineName: String {
    environment.machines.fleetMachineName(for: serverId) ?? "No machine"
  }

  public var eligibleProjects: [Project] {
    environment.projectList.fleetActiveProjects.filter {
      $0.serverId == serverId && !$0.isScratch && $0.isGitRepository
    }
  }

  public var projectIds: [UUID] {
    guard let bot = currentBot else { return draftProjectIds }
    let saved = bot.record.projects.compactMap { UUID(uuidString: $0.projectId) }
    return saved + addingProjectIds.filter { !saved.contains($0) }
  }

  public var canChangeProjects: Bool {
    editedBot == nil || environment.bots.supportsProjectChanges(on: serverId)
  }

  public var showsProjects: Bool {
    editedBot != nil || needsProject
  }

  private var needsProject: Bool {
    !environment.bots.supportsProjectlessBots(on: serverId)
  }

  public func canRemoveProject(_ id: UUID) -> Bool {
    guard editedBot != nil else { return true }
    return canChangeProjects && hasProjectToSpare && !changingProjectIds.contains(id)
  }

  private var hasProjectToSpare: Bool {
    !needsProject || projectIds.count > 1
  }

  private var currentBot: Bot? {
    editedBot.map { environment.bots.bot(serverId: $0.serverId, id: $0.id) ?? $0 }
  }

  public var selectedProjects: [Project] {
    projectIds.compactMap { id in eligibleProjects.first { $0.id == id } }
  }

  public var addableProjectGroups: [ProjectGroup] {
    environment.projectList.fleetActiveProjectGroupsByWorkspaceRecency(environment.workspaces.loadAll())
      .filter(canAdd)
  }

  private func canAdd(_ group: ProjectGroup) -> Bool {
    guard let member = group.member(on: serverId) else { return group.isGitRepository }
    return member.isGitRepository && !projectIds.contains(member.id)
  }

  public var projectCount: Int {
    projectIds.count
  }

  public var canSave: Bool {
    guard !trimmedName.isEmpty, !isSaving, !didSave else { return false }
    if editedBot != nil { return true }
    return hasRequiredProject && models?.harnessId != nil && models?.isResolving == false
  }

  private var hasRequiredProject: Bool {
    !needsProject || !selectedProjects.isEmpty
  }

  public func addProject(_ id: UUID) async {
    guard !projectIds.contains(id) else { return }
    guard let bot = currentBot else {
      draftProjectIds.append(id)
      return
    }
    guard canChangeProjects else { return }
    addingProjectIds.append(id)
    await changeProject(id) { try await $0.addProject(id, to: bot) }
    addingProjectIds.removeAll { $0 == id }
  }

  public func addProject(from group: ProjectGroup) async {
    guard let member = group.member(on: serverId) else { return await cloneProject(group) }

    await addProject(member.id)
  }

  private func cloneProject(_ group: ProjectGroup) async {
    await projectSetup.clone(group, to: serverId) { [weak self] project in
      Task { await self?.addNewProject(project) }
    }
  }

  public func addNewProject(_ project: Project) async {
    let client = environment.machines.client(for: project.serverId)
    await environment.projectList.refreshFromServer(serverId: project.serverId, client: client)
    guard project.serverId == serverId else { return }
    guard await Self.isGitRepository(project, on: client) != false else {
      errorMessage = "\(project.name) isn't a git repository, so a bot can't use it."
      return
    }

    await addProject(project.id)
  }

  private static func isGitRepository(_ project: Project, on client: any CodevisorServerClienting) async -> Bool? {
    guard let listed = try? await client.listProjects() else { return nil }

    let match = listed.first { $0.id.caseInsensitiveCompare(project.id.uuidString) == .orderedSame }
    return (try? match?.project(serverId: project.serverId))?.isGitRepository
  }

  public func removeProject(_ id: UUID) async {
    guard let bot = currentBot else {
      draftProjectIds.removeAll { $0 == id }
      return
    }
    guard projectIds.contains(id), canRemoveProject(id) else { return }
    await changeProject(id) { try await $0.removeProject(id, from: bot) }
  }

  private func changeProject(_ id: UUID, _ change: (BotListModel) async throws -> Void) async {
    changingProjectIds.insert(id)
    errorMessage = nil
    defer { changingProjectIds.remove(id) }
    do {
      try await change(environment.bots)
    } catch {
      errorMessage = ErrorReporter.userFacingMessage(for: error)
    }
  }

  public func loadModels() async {
    guard editedBot == nil else { return }
    models = nil
    await environment.warmHarnessCapabilities(for: serverId)
    let selection = BotModelSelection(
      serverId: serverId,
      client: environment.machines.client(for: serverId),
      configCache: environment.configCache,
      composerDefaults: environment.composerDefaults
    )
    models = selection
    await selection.seedDefaults()
  }

  public func loadMascotOptions() async {
    mascotOptions = nil
    let options = await fetchMascotOptions()
    guard !Task.isCancelled, let options else { return }

    mascotOptions = options
    mascot = mascot ?? options.nextBotMascot
  }

  private func fetchMascotOptions() async -> ServerBotMascotOptions? {
    let retry = MachineRetry(machineId: serverId, machines: environment.machines, policy: retryPolicy)
    var failures = 0
    while true {
      do {
        return try await retry.client().botMascotOptions()
      } catch {
        failures += 1
        guard await retry.shouldRetry(after: error, failures: failures) else { return nil }
      }
    }
  }

  @discardableResult
  public func save() async -> Bool {
    guard canSave else { return false }
    isSaving = true
    errorMessage = nil
    defer { isSaving = false }
    do {
      if let bot = editedBot {
        try await environment.bots.update(
          bot,
          ServerUpdateBotRequest(
            name: trimmedName, mascot: mascot, conversational: mode == .conversation, mode: mode.rawValue)
        )
      } else {
        guard let models, let harnessId = models.harnessId else { return false }
        createdBot = try await environment.bots.create(
          ServerCreateBotRequest(
            id: botId.uuidString.lowercased(),
            name: trimmedName,
            symbolName: symbolName,
            mascot: mascot,
            harnessId: harnessId,
            configSelections: models.configSelections,
            projectIds: selectedProjects.map { $0.id.uuidString.lowercased() },
            conversational: mode == .conversation,
            mode: mode.rawValue
          ),
          on: serverId
        )
      }
      didSave = true
      return true
    } catch {
      errorMessage = ErrorReporter.userFacingMessage(for: error)
      return false
    }
  }
}
