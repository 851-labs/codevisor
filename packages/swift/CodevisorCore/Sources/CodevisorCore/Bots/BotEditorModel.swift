import Foundation
import Observation

@MainActor
@Observable
public final class BotEditorModel {
  public let target: BotEditorTarget
  public var name: String
  public var symbolName: String
  public var serverId: String {
    didSet { if serverId != oldValue { projectIds = [] } }
  }
  public var projectIds: [UUID] = []
  public var isConversational = true
  public private(set) var models: BotModelSelection?
  public private(set) var isSaving = false
  public private(set) var didSave = false
  public private(set) var createdBot: Bot?
  public private(set) var errorMessage: String?
  @ObservationIgnored private let environment: AppEnvironment
  @ObservationIgnored private let botId = UUID()

  public init(target: BotEditorTarget, environment: AppEnvironment) {
    self.target = target
    self.environment = environment
    switch target {
    case .create:
      name = ""
      symbolName = BotIcon.fallback.systemImage
      serverId = environment.defaultBotServerId
    case let .edit(bot):
      name = bot.name
      symbolName = bot.symbolName
      serverId = bot.serverId
    }
  }

  public var editedBot: Bot? {
    if case let .edit(bot) = target { return bot }
    return nil
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

  public var selectedProjects: [Project] {
    projectIds.compactMap { id in eligibleProjects.first { $0.id == id } }
  }

  public var addableProjects: [Project] {
    eligibleProjects.filter { !projectIds.contains($0.id) }
  }

  public var projectCount: Int {
    editedBot?.record.projects.count ?? projectIds.count
  }

  public var canSave: Bool {
    guard !trimmedName.isEmpty, !isSaving, !didSave else { return false }
    if editedBot != nil { return true }
    return !selectedProjects.isEmpty && models?.harnessId != nil && models?.isResolving == false
  }

  public func addProject(_ id: UUID) {
    guard !projectIds.contains(id) else { return }
    projectIds.append(id)
  }

  public func removeProject(_ id: UUID) {
    projectIds.removeAll { $0 == id }
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

  @discardableResult
  public func save() async -> Bool {
    guard canSave else { return false }
    isSaving = true
    errorMessage = nil
    defer { isSaving = false }
    do {
      if let bot = editedBot {
        try await environment.bots.update(bot, ServerUpdateBotRequest(name: trimmedName, symbolName: symbolName))
      } else {
        guard let models, let harnessId = models.harnessId else { return false }
        createdBot = try await environment.bots.create(
          ServerCreateBotRequest(
            id: botId.uuidString.lowercased(),
            name: trimmedName,
            symbolName: symbolName,
            harnessId: harnessId,
            configSelections: models.configSelections,
            projectIds: selectedProjects.map { $0.id.uuidString.lowercased() },
            conversational: isConversational
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
