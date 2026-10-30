import ACPKit
import Foundation
import Observation

@MainActor
@Observable
public final class BotModelSelection {
  public struct HarnessModels: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let symbolName: String
    public let models: [SessionConfigSelectOption]
  }

  public private(set) var harnessId: String?
  public private(set) var options: [SessionConfigOption] = []
  public private(set) var isResolving = false
  public let serverId: String
  @ObservationIgnored private let client: any CodevisorServerClienting
  @ObservationIgnored private let configCache: ConfigOptionCache
  @ObservationIgnored private let composerDefaults: ComposerDefaultsStore
  @ObservationIgnored private let cwd: String
  @ObservationIgnored private var resolveGeneration: UInt64 = 0

  public init(
    serverId: String,
    client: any CodevisorServerClienting,
    configCache: ConfigOptionCache,
    composerDefaults: ComposerDefaultsStore,
    cwd: String = FileManager.default.temporaryDirectory.path
  ) {
    self.serverId = serverId
    self.client = client
    self.configCache = configCache
    self.composerDefaults = composerDefaults
    self.cwd = cwd
  }

  public var harnesses: [HarnessModels] {
    configCache.capabilities(forServer: serverId).compactMap { capability in
      guard let model = Self.modelOption(in: capability.configOptions) else { return nil }
      return HarnessModels(
        id: capability.harness.id,
        name: capability.harness.name,
        symbolName: capability.harness.symbolName,
        models: model.options
      )
    }
  }

  public var modelOption: SessionConfigOption? { Self.modelOption(in: options) }

  public var parameterOptions: [SessionConfigOption] { ConfigParameterOptions.ordered(options) }

  public var configSelections: [String: String] {
    Dictionary(
      options.filter { !$0.options.isEmpty }.map { ($0.id, $0.currentValue) },
      uniquingKeysWith: { first, _ in first }
    )
  }

  public func seedDefaults() async {
    guard harnessId == nil else { return }
    let available = harnesses
    let remembered = composerDefaults.lastHarnessId(for: .newWorkspace(serverId: serverId))
    guard let harness = available.first(where: { $0.id == remembered }) ?? available.first else {
      return
    }
    let modelId = Self.modelOption(in: capabilityOptions(harness.id))?.id
    let rememberedModel = modelId.flatMap { composerDefaults.configSelections(forHarness: harness.id, model: nil)[$0] }
    let selections = composerDefaults.configSelections(forHarness: harness.id, model: rememberedModel)
    await resolve(harnessId: harness.id, selections: selections)
  }

  public func chooseModel(harnessId: String, value: String) async {
    var selections = composerDefaults.configSelections(forHarness: harnessId, model: value)
    if let model = Self.modelOption(in: capabilityOptions(harnessId)) ?? modelOption {
      selections[model.id] = value
    }
    await resolve(harnessId: harnessId, selections: selections)
  }

  public func setParameter(_ optionId: String, value: String) {
    guard let index = options.firstIndex(where: { $0.id == optionId }),
      options[index].options.contains(where: { $0.value == value })
    else { return }
    options[index].currentValue = value
  }

  private func capabilityOptions(_ harnessId: String) -> [SessionConfigOption] {
    configCache.capabilities(forServer: serverId)
      .first { $0.harness.id == harnessId }?.configOptions ?? []
  }

  private func resolve(harnessId: String, selections: [String: String]) async {
    resolveGeneration &+= 1
    let generation = resolveGeneration
    self.harnessId = harnessId
    options = Self.applying(selections, to: capabilityOptions(harnessId))
    isResolving = true
    defer { if generation == resolveGeneration { isResolving = false } }
    guard
      let resolved = try? await client.capabilities(
        cwd: cwd,
        harnessId: harnessId,
        configSelections: selections
      ).harnesses.first(where: { $0.harness.id == harnessId }),
      generation == resolveGeneration
    else { return }
    options = Self.applying(selections, to: resolved.configOptions)
  }

  private static func applying(
    _ selections: [String: String],
    to options: [SessionConfigOption]
  ) -> [SessionConfigOption] {
    options.map { option in
      var updated = option
      if let value = selections[option.id], option.options.contains(where: { $0.value == value }) {
        updated.currentValue = value
      } else if !option.options.contains(where: { $0.value == option.currentValue }),
        let first = option.options.first
      {
        updated.currentValue = first.value
      }
      return updated
    }
  }

  private static func modelOption(in options: [SessionConfigOption]) -> SessionConfigOption? {
    options.first { $0.category == SessionConfigOption.Category.model && !$0.options.isEmpty }
  }
}
