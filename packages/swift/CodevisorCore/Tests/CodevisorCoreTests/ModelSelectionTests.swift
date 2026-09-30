import ACPKit
import Foundation
import Testing
import CodevisorTestSupport

@testable import CodevisorCore

/// Model picker ownership: New Chat defaults belong to unsent composers, an
/// existing chat's configuration is its own, and the picker never shows
/// more than one spinner.
@MainActor
@Suite("Model selection")
struct ModelSelectionTests {
  // MARK: - Presentation

  @Test("The model controls never show more than one spinner")
  func presentationHasAtMostOneSpinner() {
    for bits in 0..<16 {
      let presentation = ModelPickerPresentation(
        isModelListKnown: bits & 1 != 0,
        selectedModelName: bits & 2 != 0 ? "Opus" : nil,
        hasSettings: bits & 4 != 0,
        isResolvingSettings: bits & 8 != 0
      )
      #expect(presentation.spinnerCount <= 1, "combination \(bits)")
    }
  }

  @Test("Presentation states follow the picker rules")
  func presentationStates() {
    // Unknown list: a single spinner, no parameters chip.
    let unknown = ModelPickerPresentation(
      isModelListKnown: false, selectedModelName: "Opus",
      hasSettings: true, isResolvingSettings: true
    )
    #expect(unknown.modelChip == .loading)
    #expect(!unknown.showsSettingsChip)
    #expect(unknown.spinnerCount == 1)

    // Known list without a pick.
    let unselected = ModelPickerPresentation(
      isModelListKnown: true, selectedModelName: nil,
      hasSettings: false, isResolvingSettings: false
    )
    #expect(unselected.modelChipTitle == "Select a model")
    #expect(unselected.spinnerCount == 0)

    // Settings already on screen stay put while fresher ones load.
    let refreshing = ModelPickerPresentation(
      isModelListKnown: true, selectedModelName: "Opus",
      hasSettings: true, isResolvingSettings: true
    )
    #expect(refreshing.modelChip == .model(name: "Opus"))
    #expect(refreshing.showsSettingsChip)
    #expect(refreshing.spinnerCount == 0)

    // A pick with no settings to show yet: the name shows at once and the
    // parameters chip is the only spinner.
    let picked = ModelPickerPresentation(
      isModelListKnown: true, selectedModelName: "Sonnet",
      hasSettings: false, isResolvingSettings: true
    )
    #expect(picked.modelChip == .model(name: "Sonnet"))
    #expect(picked.showsSettingsChip)
    #expect(picked.showsSettingsSpinner)
    #expect(picked.spinnerCount == 1)
  }

  // MARK: - Existing chats

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
    // The catalog's own current value is a fresh-session default.
    cache.store([catalog(currentModel: "gpt-5.6")], forServer: "machine-a")
    let chat = session(configSelections: ["model": "gpt-5.5"])
    let controller = controller(for: chat, cache: cache, defaults: defaults)

    // Binding, reconciling, or seeding defaults never paints New Chat
    // values over the chat's own.
    controller.applyComposerDefaults()
    controller.reconcileExistingSession(chat)
    #expect(controller.modelOption?.currentValue == "gpt-5.5")

    // A pick while the runtime is still connecting is staged, not
    // dropped, and stays out of New Chat defaults.
    #expect(controller.isConnectingToHarness)
    await controller.setConfigOption("model", "gpt-5.7")
    #expect(controller.modelOption?.currentValue == "gpt-5.7")
    #expect(controller.pendingConfigByHarness["codex"]?["model"] == "gpt-5.7")
    #expect(
      defaults.configSelections(forHarness: "codex", in: .newWorkspace(serverId: "machine-a"))
        == ["model": "gpt-5.6"])
  }

  @Test("An existing chat without its own model spins instead of showing a catalog default")
  func existingChatWithoutSavedModelWaits() {
    let cache = ConfigOptionCache(store: InMemoryStore())
    cache.store([catalog(currentModel: "gpt-5.6")], forServer: "machine-a")
    let controller = controller(for: session(configSelections: nil), cache: cache)

    #expect(controller.modelPickerPresentation.modelChip == .loading)
    #expect(controller.modelPickerPresentation.spinnerCount == 1)
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

  // MARK: - Drafts

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

    // Changing a setting before picking a model must not record the
    // harness default as the user's model.
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
    // Like Claude before its first turn: no current model, so the catalog
    // carries no model-specific settings.
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

    // Neither the catalog's current value nor its first option stands in.
    #expect(controller.modelPickerPresentation.modelChip == .selectModel)
    #expect(
      controller.modelUnavailableMessage == "gpt-5.4 is no longer available. Select another model.")

    // Dismissing hides only the notice: the chip still asks for a model.
    controller.dismissModelUnavailableNotice()
    #expect(controller.modelUnavailableMessage == nil)
    #expect(controller.modelPickerPresentation.modelChip == .selectModel)
    #expect(controller.requiresModelSelection)

    await controller.chooseModel("gpt-5.5", name: "GPT-5.5", harnessId: "codex")

    #expect(controller.modelUnavailableMessage == nil)
    #expect(controller.modelPickerPresentation.modelChip == .model(name: "GPT-5.5"))
    // The explicit pick is the machine's new default.
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
    // The draft started checking its remembered model with the server...
    #expect(controller.modelPickerPresentation.modelChip == .loading)

    // ...and then became an existing chat with its own saved model.
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

  // MARK: - Runtime races

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
    // The runtime's snapshot from before the pick arrives mid-flight.
    model.apply(.update(.configOptionUpdate(catalog(currentModel: "gpt-5.5").configOptions)))
    #expect(model.configOptions.first?.currentValue == "gpt-5.6")

    release.yield()
    release.finish()
    #expect(await pick.value)

    // Once settled, runtime updates apply normally again.
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
    controller.pendingConfigByHarness["codex"] = ["model": "gpt-5.6", "effort": "high"]

    let apply = Task { await controller.applyPendingRuntimeConfiguration(to: model) }
    await awaitObserved { client.configUpdates.count == 1 }
    // The runtime is still validating, so this pick is staged.
    #expect(controller.isConnectingToHarness)
    await controller.setConfigOption("effort", "low")
    release.yield()
    release.finish()
    await apply.value

    #expect(client.configUpdates.map(\.0) == ["model", "effort"])
    #expect(client.configUpdates.map(\.1) == ["gpt-5.6", "low"])
    #expect(controller.pendingConfigByHarness["codex"] == nil)
  }

  // MARK: - Fixtures

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
