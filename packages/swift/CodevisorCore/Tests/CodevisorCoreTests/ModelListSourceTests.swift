import ACPKit
import Foundation
import Testing
import CodevisorTestSupport

@testable import CodevisorCore

@MainActor
@Suite("Model list source")
struct ModelListSourceTests {
  private static var reported: OfferedModels { OfferedModels(["gpt-5.5", "gpt-5.6", "gpt-5.7"]) }

  @Test("An existing chat offers the machine's current models, not the list its agent last reported")
  func existingChatOffersMachineModels() {
    let cache = ConfigOptionCache(store: InMemoryStore())
    cache.store(
      [OfferedModels(["gpt-5.5", "gpt-6"]).catalog(currentModel: "")], forServer: "machine-a")
    let controller = controller(for: session(configSelections: ["model": "gpt-5.5"]), cache: cache)
    controller.configOptionsByHarness["codex"] = Self.reported.catalog(currentModel: "gpt-5.5").configOptions

    #expect(controller.modelOption?.options.map(\.value) == ["gpt-5.5", "gpt-6"])
    #expect(controller.modelPickerPresentation.modelChip == .model(name: "GPT-5.5"))
  }

  @Test("An existing chat keeps naming its model after the machine stops offering it")
  func existingChatNamesModelMachineStoppedOffering() {
    let cache = ConfigOptionCache(store: InMemoryStore())
    cache.store(
      [OfferedModels(["gpt-5.5", "gpt-6"]).catalog(currentModel: "")], forServer: "machine-a")
    let controller = controller(for: session(configSelections: ["model": "gpt-5.7"]), cache: cache)
    controller.configOptionsByHarness["codex"] = Self.reported.catalog(currentModel: "gpt-5.7").configOptions

    #expect(controller.modelOption?.options.map(\.value) == ["gpt-5.5", "gpt-6"])
    #expect(controller.modelPickerPresentation.modelChip == .model(name: "GPT-5.7"))
    #expect(!controller.requiresModelSelection)
  }

  @Test("Opening an existing chat's picker refetches the machine's stale model list once")
  func existingChatPickerRevalidatesStaleModels() async {
    let offered = OfferedModels(["gpt-5.5", "gpt-5.6", "gpt-5.7"])
    let fetches = OfferedModels([])
    let client = SyncFakeServerClient(projects: [], sessions: [])
    client.capabilitiesHandler = { _ in
      fetches.values.append("fetch")
      return ServerCapabilities(harnesses: [offered.catalog(currentModel: "")])
    }
    let cache = ConfigOptionCache(store: InMemoryStore())
    cache.store([offered.catalog(currentModel: "")], forServer: "machine-a")
    let controller = controller(
      for: session(configSelections: ["model": "gpt-5.5"]), cache: cache, client: client)
    offered.values = ["gpt-5.5", "gpt-6"]

    await controller.revalidateHarnessCapabilitiesIfStale()
    #expect(fetches.values.count == 1)
    #expect(controller.modelOption?.options.map(\.value) == ["gpt-5.5", "gpt-6"])

    await controller.revalidateHarnessCapabilitiesIfStale()
    #expect(fetches.values.count == 1)
  }

  @Test("A draft's picker shows the machine's current models after a refresh")
  func draftPickerFollowsRefreshedCatalog() async {
    let defaults = Self.rememberedDefaults(model: "gpt-5.5")
    let client = SyncFakeServerClient(projects: [], sessions: [])
    let offered = OfferedModels(["gpt-5.5", "gpt-5.6", "gpt-5.7"])
    client.capabilitiesHandler = { _ in
      ServerCapabilities(harnesses: [offered.catalog(currentModel: "")])
    }
    client.resolvedCapabilitiesHandler = { _, _, selections in
      ServerCapabilities(harnesses: [offered.catalog(currentModel: selections["model"] ?? "")])
    }
    let controller = draft(defaults: defaults, client: client)
    await controller.prepare()
    #expect(controller.modelOption?.options.map(\.value) == ["gpt-5.5", "gpt-5.6", "gpt-5.7"])

    offered.values = ["gpt-5.5", "gpt-6"]
    await controller.refreshHarnessCapabilities()

    #expect(controller.modelOption?.options.map(\.value) == ["gpt-5.5", "gpt-6"])
    #expect(controller.modelPickerPresentation.modelChip == .model(name: "GPT-5.5"))
  }

  @Test("Opening the picker refetches a stale catalog and keeps the cached one meanwhile")
  func pickerOpenRevalidatesStaleCatalog() async {
    let defaults = Self.rememberedDefaults(model: "gpt-5.5")
    let client = SyncFakeServerClient(projects: [], sessions: [])
    let offered = OfferedModels(["gpt-5.5", "gpt-5.6", "gpt-5.7"])
    let fetches = OfferedModels([])
    client.capabilitiesHandler = { _ in
      fetches.values.append("fetch")
      return ServerCapabilities(harnesses: [offered.catalog(currentModel: "")])
    }
    client.resolvedCapabilitiesHandler = { _, _, selections in
      ServerCapabilities(harnesses: [offered.catalog(currentModel: selections["model"] ?? "")])
    }
    let cache = ConfigOptionCache(store: InMemoryStore())
    cache.store([offered.catalog(currentModel: "")], forServer: "machine-a")
    let controller = draft(defaults: defaults, client: client, cache: cache)
    offered.values = ["gpt-5.5", "gpt-6"]

    await controller.revalidateHarnessCapabilitiesIfStale()
    #expect(fetches.values.count == 1)
    #expect(controller.modelOption?.options.map(\.value) == ["gpt-5.5", "gpt-6"])

    await controller.revalidateHarnessCapabilitiesIfStale()
    #expect(fetches.values.count == 1)
  }

  private func draft(
    defaults: ComposerDefaultsStore,
    client: SyncFakeServerClient,
    cache: ConfigOptionCache = ConfigOptionCache(store: InMemoryStore())
  ) -> SessionController {
    let controller = SessionController(
      project: Project.fromFolder(URL(fileURLWithPath: "/tmp/machine-a"), serverId: "machine-a"),
      configCache: cache,
      composerDefaults: defaults,
      serverClient: client
    )
    controller.applyComposerDefaults()
    return controller
  }

  private func controller(
    for chat: ChatSession,
    cache: ConfigOptionCache,
    client: SyncFakeServerClient? = nil
  ) -> SessionController {
    let controller = SessionController(
      project: Project.fromFolder(
        URL(fileURLWithPath: "/tmp/machine-a"),
        id: chat.projectId,
        serverId: chat.serverId
      ),
      configCache: cache,
      serverClient: client
    )
    controller.configureExistingSession(chat)
    return controller
  }

  private static func rememberedDefaults(model: String) -> ComposerDefaultsStore {
    let defaults = ComposerDefaultsStore(store: InMemoryStore())
    defaults.rememberHarnessSelection(serverId: "machine-a", harnessId: "codex")
    defaults.rememberConfigSelections(
      harnessId: "codex", modelOptionId: "model",
      configValues: ["model": model]
    )
    return defaults
  }

  private func session(configSelections: [String: String]?) -> ChatSession {
    ChatSession(
      projectId: UUID(),
      serverId: "machine-a",
      harnessId: "codex",
      agentSessionId: "agent-1",
      title: "Chat",
      cwd: "/tmp/machine-a",
      configSelections: configSelections,
      createdAt: Date(timeIntervalSince1970: 1)
    )
  }
}

private final class OfferedModels: @unchecked Sendable {
  var values: [String]

  init(_ values: [String]) { self.values = values }

  func catalog(currentModel: String) -> ServerHarnessCapability {
    ServerHarnessCapability(
      harness: ServerHarness(
        id: "codex",
        name: "Codex",
        symbolName: "chevron.left.forwardslash.chevron.right",
        source: "registry",
        launchKind: "executable",
        enabled: true,
        readiness: ServerHarnessReadiness(state: "ready")
      ),
      modes: nil,
      configOptions: [
        SessionConfigOption(
          id: "model",
          name: "Model",
          category: SessionConfigOption.Category.model,
          currentValue: currentModel,
          options: values.map { SessionConfigSelectOption(value: $0, name: $0.uppercased()) }
        ),
        SessionConfigOption(
          id: "effort",
          name: "Reasoning",
          category: SessionConfigOption.Category.thoughtLevel,
          currentValue: "medium",
          options: ["low", "medium", "high"].map {
            SessionConfigSelectOption(value: $0, name: $0.capitalized)
          }
        ),
      ],
      supportsGoals: false
    )
  }
}
