import ACPKit
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Per-model composer settings")
struct PerModelComposerSettingsTests {
  @Test("Switching models restores each model's own speed and thinking, and a new model gets its defaults")
  func draftSwitchRestoresEachModel() async {
    let defaults = ComposerDefaultsStore(store: InMemoryStore())
    defaults.rememberHarnessSelection(serverId: "machine-a", harnessId: "codex")
    let controller = draft(on: "machine-a", defaults: defaults, client: client())
    await controller.prepare()

    await controller.chooseModel("gpt-5.6", name: "GPT-5.6", harnessId: "codex")
    await controller.setConfigOption("speed", "fast")
    await controller.setConfigOption("effort", "high")
    await controller.chooseModel("gpt-5.7", name: "GPT-5.7", harnessId: "codex")

    #expect(controller.speedOption?.currentValue == "standard")
    #expect(controller.thoughtLevelOptions.first?.currentValue == "medium")

    await controller.chooseModel("gpt-5.6", name: "GPT-5.6", harnessId: "codex")

    #expect(controller.speedOption?.currentValue == "fast")
    #expect(controller.thoughtLevelOptions.first?.currentValue == "high")
    #expect(defaults.configSelections(forHarness: "codex", model: nil) == ["model": "gpt-5.6"])
    #expect(defaults.configSelections(forHarness: "codex", model: "gpt-5.7")["speed"] == nil)
  }

  @Test("Remembered picks apply on another machine, falling back where it doesn't offer them")
  func rememberedPicksFollowAcrossMachines() async {
    let defaults = ComposerDefaultsStore(store: InMemoryStore())
    defaults.rememberHarnessSelection(serverId: "machine-b", harnessId: "codex")
    defaults.rememberConfigSelections(
      harnessId: "codex",
      modelOptionId: "model",
      configValues: ["model": "gpt-5.6", "effort": "high", "speed": "fast"]
    )
    let controller = draft(on: "machine-b", defaults: defaults, client: client(effortLevels: ["low", "medium"]))

    await controller.prepare()

    #expect(controller.modelPickerPresentation.modelChip == .model(name: "GPT-5.6"))
    #expect(controller.speedOption?.currentValue == "fast")
    #expect(controller.thoughtLevelOptions.first?.currentValue == "medium")
  }

  @Test("An existing chat's model switch restores that model's settings or its defaults, without remembering")
  func existingChatSwitchRestoresModelSettings() async {
    let defaults = ComposerDefaultsStore(store: InMemoryStore())
    defaults.rememberConfigSelections(
      harnessId: "codex",
      modelOptionId: "model",
      configValues: ["model": "gpt-5.7", "effort": "low"]
    )
    let cache = ConfigOptionCache(store: InMemoryStore())
    cache.store([catalog(model: "gpt-5.5")], forServer: "machine-a")
    let controller = SessionController(
      project: Project.fromFolder(URL(fileURLWithPath: "/tmp/machine-a"), serverId: "machine-a"),
      configCache: cache,
      composerDefaults: defaults,
      serverClient: client()
    )
    controller.configureExistingSession(chat(selections: ["model": "gpt-5.6", "effort": "high", "speed": "fast"]))

    await controller.chooseModel("gpt-5.7", name: "GPT-5.7", harnessId: "codex")

    #expect(controller.modelOption?.currentValue == "gpt-5.7")
    #expect(controller.thoughtLevelOptions.first?.currentValue == "low")
    #expect(controller.speedOption?.currentValue == "standard")
    #expect(defaults.configSelections(forHarness: "codex", model: "gpt-5.7") == ["model": "gpt-5.7", "effort": "low"])
  }

  private func draft(
    on serverId: String,
    defaults: ComposerDefaultsStore,
    client: SyncFakeServerClient
  ) -> SessionController {
    let controller = SessionController(
      project: Project.fromFolder(URL(fileURLWithPath: "/tmp/\(serverId)"), serverId: serverId),
      configCache: ConfigOptionCache(store: InMemoryStore()),
      composerDefaults: defaults,
      serverClient: client
    )
    controller.applyComposerDefaults()
    return controller
  }

  private func client(effortLevels: [String] = ["low", "medium", "high"]) -> SyncFakeServerClient {
    let client = SyncFakeServerClient(projects: [], sessions: [])
    client.capabilitiesHandler = { _ in
      ServerCapabilities(harnesses: [catalog(model: "gpt-5.5", effortLevels: effortLevels)])
    }
    client.resolvedCapabilitiesHandler = { _, _, selections in
      ServerCapabilities(harnesses: [
        catalog(model: selections["model"] ?? "", effortLevels: effortLevels, selections: selections)
      ])
    }
    return client
  }

  private func chat(selections: [String: String]) -> ChatSession {
    ChatSession(
      projectId: UUID(),
      serverId: "machine-a",
      harnessId: "codex",
      agentSessionId: "agent-1",
      title: "Chat",
      cwd: "/tmp/machine-a",
      configSelections: selections,
      createdAt: Date(timeIntervalSince1970: 1)
    )
  }
}

private func catalog(
  model: String,
  effortLevels: [String] = ["low", "medium", "high"],
  selections: [String: String] = [:]
) -> ServerHarnessCapability {
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
      option(
        "model", category: SessionConfigOption.Category.model, values: ["gpt-5.5", "gpt-5.6", "gpt-5.7"], current: model
      ),
      option(
        "effort", category: SessionConfigOption.Category.thoughtLevel, values: effortLevels,
        selected: selections["effort"], fallback: "medium"),
      option(
        "speed", category: SessionConfigOption.Category.speed, values: ["standard", "fast"],
        selected: selections["speed"], fallback: "standard"),
    ],
    supportsGoals: false
  )
}

private func option(
  _ id: String,
  category: String,
  values: [String],
  selected: String? = nil,
  fallback: String = "",
  current: String? = nil
) -> SessionConfigOption {
  let offered = selected.flatMap { values.contains($0) ? $0 : nil }
  return SessionConfigOption(
    id: id,
    name: id.capitalized,
    category: category,
    currentValue: current ?? offered ?? fallback,
    options: values.map { SessionConfigSelectOption(value: $0, name: $0.uppercased()) }
  )
}
