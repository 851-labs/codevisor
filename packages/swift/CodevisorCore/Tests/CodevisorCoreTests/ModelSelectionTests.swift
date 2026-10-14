import ACPKit
import Foundation
import Testing
import CodevisorTestSupport

@testable import CodevisorCore

@MainActor
@Suite("Model selection")
struct ModelSelectionTests {
  @Test("The model controls never show more than one spinner")
  func presentationHasAtMostOneSpinner() {
    for bits in 0..<16 {
      let presentation = ModelPickerPresentation(
        isModelListKnown: bits & 1 != 0,
        selectedModelName: bits & 2 != 0 ? "Opus" : nil,
        hasSettings: bits & 4 != 0,
        isResolvingSettings: bits & 8 != 0
      )
      #expect(
        !(presentation.modelChip == .loading && presentation.showsSettingsSpinner), "combination \(bits)")
    }
  }

  @Test("Presentation states follow the picker rules")
  func presentationStates() {
    let unknown = ModelPickerPresentation(
      isModelListKnown: false, selectedModelName: "Opus",
      hasSettings: true, isResolvingSettings: true
    )
    #expect(unknown.modelChip == .loading)
    #expect(!unknown.showsSettingsChip)
    #expect(!unknown.showsSettingsSpinner)

    let unselected = ModelPickerPresentation(
      isModelListKnown: true, selectedModelName: nil,
      hasSettings: false, isResolvingSettings: false
    )
    #expect(unselected.modelChipTitle == "Select a model")
    #expect(!unselected.showsSettingsSpinner)

    let refreshing = ModelPickerPresentation(
      isModelListKnown: true, selectedModelName: "Opus",
      hasSettings: true, isResolvingSettings: true
    )
    #expect(refreshing.modelChip == .model(name: "Opus"))
    #expect(refreshing.showsSettingsChip)
    #expect(!refreshing.showsSettingsSpinner)

    let picked = ModelPickerPresentation(
      isModelListKnown: true, selectedModelName: "Sonnet",
      hasSettings: false, isResolvingSettings: true
    )
    #expect(picked.modelChip == .model(name: "Sonnet"))
    #expect(picked.showsSettingsChip)
    #expect(picked.showsSettingsSpinner)
  }

  @Test("An existing chat never reads or writes New Chat defaults")
  func existingChatIsIsolatedFromDefaults() async {
    let defaults = ComposerDefaultsStore(store: InMemoryStore())
    defaults.rememberHarnessSelection(serverId: "machine-a", harnessId: "codex")
    defaults.rememberConfigSelections(
      in: .newWorkspace(serverId: "machine-a"),
      harnessId: "codex",
      configValues: ["model": "gpt-5.6"]
    )
    let cache = ConfigOptionCache(store: InMemoryStore())
    cache.store([catalog(currentModel: "gpt-5.6")], forServer: "machine-a")
    let chat = session(configSelections: ["model": "gpt-5.5"])
    let controller = controller(for: chat, cache: cache, defaults: defaults)

    controller.applyComposerDefaults()
    controller.reconcileExistingSession(chat)
    #expect(controller.modelOption?.currentValue == "gpt-5.5")

    #expect(controller.isConnectingToHarness)
    await controller.setConfigOption("model", "gpt-5.7")
    #expect(controller.modelOption?.currentValue == "gpt-5.7")
    #expect(controller.pendingConfiguration.value(for: "model", in: "codex") == "gpt-5.7")
    #expect(
      defaults.configSelections(forHarness: "codex", in: .newWorkspace(serverId: "machine-a"))
        == ["model": "gpt-5.6"])
  }

  @Test("A chat another device starts shows that device's picks, not this one's defaults")
  func chatStartedElsewhereDropsDraftPicks() {
    let defaults = rememberedDefaults(model: "gpt-5.6")
    let cache = ConfigOptionCache(store: InMemoryStore())
    cache.store([catalog(currentModel: "gpt-5.6")], forServer: "machine-a")
    var empty = session(configSelections: nil)
    empty.agentSessionId = ""
    let controller = controller(for: empty, cache: cache, defaults: defaults)
    controller.applyComposerDefaults()
    #expect(controller.modelOption?.currentValue == "gpt-5.6")

    var started = empty
    started.agentSessionId = "agent-1"
    started.configSelections = ["model": "gpt-5.5"]
    controller.reconcileExistingSession(started)

    #expect(controller.modelOption?.currentValue == "gpt-5.5")
    #expect(controller.pendingConfiguration.values(for: "codex") == nil)
  }

  @Test("An existing chat without its own model spins instead of showing a catalog default")
  func existingChatWithoutSavedModelWaits() {
    let cache = ConfigOptionCache(store: InMemoryStore())
    cache.store([catalog(currentModel: "gpt-5.6")], forServer: "machine-a")
    let controller = controller(for: session(configSelections: nil), cache: cache)

    #expect(controller.modelPickerPresentation.modelChip == .loading)
  }

  @Test("An existing chat whose model was withdrawn asks for a new one")
  func existingChatUnavailableModel() async {
    let cache = ConfigOptionCache(store: InMemoryStore())
    cache.store([catalog(currentModel: "gpt-5.6")], forServer: "machine-a")
    var chat = session(configSelections: ["model": "gpt-5.5"])
    chat.unavailableConfigSelections = ["model": "gpt-5.5"]
    let controller = controller(for: chat, cache: cache)
    controller.composerText = "continue"

    #expect(controller.modelPickerPresentation.modelChip == .selectModel)
    #expect(
      controller.modelUnavailableMessage == "GPT-5.5 is no longer available. Select another model.")
    #expect(controller.requiresModelSelection)
    #expect(!controller.canSend)

    await controller.chooseModel("gpt-5.6", name: "GPT-5.6", harnessId: "codex")

    #expect(controller.modelUnavailableMessage == nil)
    #expect(controller.modelPickerPresentation.modelChip == .model(name: "GPT-5.6"))
    #expect(!controller.requiresModelSelection)
  }

  @Test("A draft with no model pick asks for one instead of showing the harness default")
  func draftWithoutPickAsksForModel() async {
    let defaults = ComposerDefaultsStore(store: InMemoryStore())
    defaults.rememberHarnessSelection(serverId: "machine-a", harnessId: "codex")
    let client = SyncFakeServerClient(projects: [], sessions: [])
    client.capabilitiesHandler = { _ in
      ServerCapabilities(harnesses: [catalog(currentModel: "gpt-5.6")])
    }
    let controller = draft(defaults: defaults, client: client)

    await controller.prepare()

    #expect(controller.modelPickerPresentation.modelChip == .selectModel)
    #expect(controller.requiresModelSelection)

    await controller.setConfigOption("effort", "high")
    #expect(
      defaults.configSelections(forHarness: "codex", in: .newWorkspace(serverId: "machine-a"))["model"]
        == nil)

    await controller.chooseModel("gpt-5.7", name: "GPT-5.7", harnessId: "codex")

    #expect(controller.modelPickerPresentation.modelChip == .model(name: "GPT-5.7"))
    #expect(!controller.requiresModelSelection)
  }

  @Test("A draft's model shows its own settings, keeping valid remembered values")
  func draftModelSettingsAreInspected() async {
    let defaults = ComposerDefaultsStore(store: InMemoryStore())
    defaults.rememberHarnessSelection(serverId: "machine-a", harnessId: "codex")
    defaults.rememberConfigSelections(
      in: .newWorkspace(serverId: "machine-a"),
      harnessId: "codex",
      configValues: ["model": "gpt-5.5", "effort": "high"]
    )
    var generic = catalog(currentModel: "")
    generic.configOptions.removeAll { $0.id == "effort" }
    let client = SyncFakeServerClient(projects: [], sessions: [])
    client.capabilitiesHandler = { [generic] _ in ServerCapabilities(harnesses: [generic]) }
    client.resolvedCapabilitiesHandler = { _, _, selections in
      var resolved = catalog(currentModel: selections["model"] ?? "")
      resolved.configOptions[1].currentValue = "medium"
      return ServerCapabilities(harnesses: [resolved])
    }
    let controller = draft(defaults: defaults, client: client)

    await controller.prepare()

    #expect(controller.modelPickerPresentation.modelChip == .model(name: "GPT-5.5"))
    #expect(controller.thoughtLevelOptions.first?.currentValue == "high")
    #expect(controller.modelPickerPresentation.showsSettingsChip)
    #expect(!controller.modelPickerPresentation.showsSettingsSpinner)
  }

  @Test("A remembered model the machine no longer offers asks for another")
  func draftRememberedModelWithdrawn() async {
    let defaults = rememberedDefaults(model: "gpt-5.4")
    let client = SyncFakeServerClient(projects: [], sessions: [])
    client.capabilitiesHandler = { _ in
      ServerCapabilities(harnesses: [catalog(currentModel: "gpt-5.6")])
    }
    client.resolvedCapabilitiesHandler = { _, _, selections in
      var resolved = catalog(currentModel: "gpt-5.6")
      resolved.unappliedConfigSelections = ["model": selections["model"] ?? ""]
      return ServerCapabilities(harnesses: [resolved])
    }
    let controller = draft(defaults: defaults, client: client)

    await controller.prepare()

    #expect(controller.modelPickerPresentation.modelChip == .selectModel)
    #expect(
      controller.modelUnavailableMessage == "gpt-5.4 is no longer available. Select another model.")

    controller.dismissModelUnavailableNotice()
    #expect(controller.modelUnavailableMessage == nil)
    #expect(controller.modelPickerPresentation.modelChip == .selectModel)
    #expect(controller.requiresModelSelection)

    await controller.chooseModel("gpt-5.5", name: "GPT-5.5", harnessId: "codex")

    #expect(controller.modelUnavailableMessage == nil)
    #expect(controller.modelPickerPresentation.modelChip == .model(name: "GPT-5.5"))
    #expect(
      defaults.configSelections(forHarness: "codex", in: .newWorkspace(serverId: "machine-a"))["model"]
        == "gpt-5.5")
  }

  @Test("A draft's pending model check never leaves the chat it becomes spinning")
  func existingChatIgnoresDraftModelCheck() async {
    let defaults = rememberedDefaults(model: "gpt-4.1-retired")
    let client = SyncFakeServerClient(projects: [], sessions: [])
    client.capabilitiesHandler = { _ in
      ServerCapabilities(harnesses: [catalog(currentModel: "gpt-5.6")])
    }
    let controller = draft(defaults: defaults, client: client)
    controller.configOptionsByHarness["codex"] = catalog(currentModel: "gpt-5.6").configOptions
    controller.seedRememberedConfig()
    #expect(controller.modelPickerPresentation.modelChip == .loading)

    controller.configureExistingSession(session(configSelections: ["model": "gpt-5.5"]))

    #expect(controller.modelPickerPresentation.modelChip == .model(name: "GPT-5.5"))
    #expect(controller.modelUnavailableMessage == nil)
  }

  @Test("A remembered model id the server reconciled is adopted as the new default")
  func draftRememberedModelRenamed() async {
    let defaults = rememberedDefaults(model: "gpt-5.5-preview")
    let client = SyncFakeServerClient(projects: [], sessions: [])
    client.capabilitiesHandler = { _ in
      ServerCapabilities(harnesses: [catalog(currentModel: "")])
    }
    client.resolvedCapabilitiesHandler = { _, _, _ in
      var resolved = catalog(currentModel: "gpt-5.5")
      resolved.unappliedConfigSelections = [:]
      return ServerCapabilities(harnesses: [resolved])
    }
    let controller = draft(defaults: defaults, client: client)

    await controller.prepare()

    #expect(controller.modelPickerPresentation.modelChip == .model(name: "GPT-5.5"))
    #expect(controller.modelUnavailableMessage == nil)
    #expect(
      defaults.configSelections(forHarness: "codex", in: .newWorkspace(serverId: "machine-a"))["model"]
        == "gpt-5.5")
  }

  @Test("A config update older than an in-flight pick does not roll it back")
  func staleConfigUpdateKeepsInFlightPick() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let (gate, release) = AsyncStream.makeStream(of: Void.self)
    client.holdConfigUpdates(until: gate)
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString,
      configOptions: catalog(currentModel: "gpt-5.5").configOptions
    )

    let pick = Task { await model.setConfigOption(configId: "model", value: "gpt-5.6") }
    await awaitObserved { !client.configUpdates.isEmpty }
    model.apply(.update(.configOptionUpdate(catalog(currentModel: "gpt-5.5").configOptions)))
    #expect(model.configOptions.first?.currentValue == "gpt-5.6")

    release.yield()
    release.finish()
    #expect(await pick.value)

    model.apply(.update(.configOptionUpdate(catalog(currentModel: "gpt-5.7").configOptions)))
    #expect(model.configOptions.first?.currentValue == "gpt-5.7")
  }

  @Test("A pick staged while pending configuration is applied survives and is applied")
  func pickDuringPendingApplySurvives() async {
    let chat = session(configSelections: ["model": "gpt-5.5"])
    let client = FakeSessionServerClient(sessionId: chat.id)
    let (gate, release) = AsyncStream.makeStream(of: Void.self)
    client.holdConfigUpdates(until: gate)
    let controller = controller(for: chat, cache: ConfigOptionCache(store: InMemoryStore()))
    controller.connectedHarnessId = "codex"
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: chat.id),
      sessionId: chat.id.uuidString,
      configOptions: catalog(currentModel: "gpt-5.5").configOptions
    )
    controller.model = model
    controller.pendingConfiguration.replaceValues(["model": "gpt-5.6", "effort": "high"], for: "codex")

    let apply = Task { await controller.pendingConfiguration.apply(to: model) }
    await awaitObserved { client.configUpdates.count == 1 }
    #expect(controller.isConnectingToHarness)
    await controller.setConfigOption("effort", "low")
    release.yield()
    release.finish()
    await apply.value

    #expect(client.configUpdates.map(\.0) == ["model", "effort"])
    #expect(client.configUpdates.map(\.1) == ["gpt-5.6", "low"])
    #expect(controller.pendingConfiguration.values(for: "codex") == nil)
  }

  private func controller(
    for chat: ChatSession,
    cache: ConfigOptionCache,
    defaults: ComposerDefaultsStore? = nil
  ) -> SessionController {
    let controller = SessionController(
      project: Project.fromFolder(
        URL(fileURLWithPath: "/tmp/machine-a"),
        id: chat.projectId,
        serverId: chat.serverId
      ),
      configCache: cache,
      composerDefaults: defaults
    )
    controller.configureExistingSession(chat)
    return controller
  }

  private func draft(
    defaults: ComposerDefaultsStore,
    client: SyncFakeServerClient
  ) -> SessionController {
    let controller = SessionController(
      project: Project.fromFolder(URL(fileURLWithPath: "/tmp/machine-a"), serverId: "machine-a"),
      configCache: ConfigOptionCache(store: InMemoryStore()),
      composerDefaults: defaults,
      serverClient: client
    )
    controller.applyComposerDefaults()
    return controller
  }

  private func rememberedDefaults(model: String) -> ComposerDefaultsStore {
    let defaults = ComposerDefaultsStore(store: InMemoryStore())
    defaults.rememberHarnessSelection(serverId: "machine-a", harnessId: "codex")
    defaults.rememberConfigSelections(
      in: .newWorkspace(serverId: "machine-a"),
      harnessId: "codex",
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

private func catalog(currentModel: String) -> ServerHarnessCapability {
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
        options: ["gpt-5.5", "gpt-5.6", "gpt-5.7"].map {
          SessionConfigSelectOption(value: $0, name: $0.uppercased())
        }
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
