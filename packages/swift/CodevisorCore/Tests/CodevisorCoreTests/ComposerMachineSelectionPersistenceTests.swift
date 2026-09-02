import ACPKit
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Composer machine-selection persistence")
struct ComposerMachineSelectionPersistenceTests {
  @Test("An explicit picker action wins over an in-flight automatic carry")
  func explicitPickerSupersedesCarry() async {
    let defaults = ComposerDefaultsStore(store: InMemoryStore())
    let sourceCodex = capability(
      harnessId: "codex",
      currentModel: "gpt-5.6-sol",
      models: ["gpt-5.6-sol"],
      currentReasoning: "xhigh",
      reasoning: ["low", "xhigh"]
    )
    let destinationCodex = capability(
      harnessId: "codex",
      currentModel: "gpt-5.6-sol",
      models: ["gpt-5.6-sol"],
      currentReasoning: "low",
      reasoning: ["low", "xhigh"]
    )
    let resolvedCodex = sourceCodex
    let gate = FetchGate()
    let client = SyncFakeServerClient(projects: [], sessions: [])
    client.capabilitiesHandler = { _ in
      ServerCapabilities(harnesses: [destinationCodex])
    }
    client.resolvedCapabilitiesHandler = { _, _, _ in
      await gate.wait()
      return ServerCapabilities(harnesses: [resolvedCodex])
    }
    let controller = SessionController(
      project: project(serverId: "machine-a"),
      configCache: ConfigOptionCache(store: InMemoryStore()),
      composerDefaults: defaults
    )
    controller.harnesses = [sourceCodex.harness]
    controller.selectedHarnessId = "codex"
    controller.configOptionsByHarness["codex"] = sourceCodex.configOptions

    async let retarget: Void = controller.retarget(
      to: project(serverId: "machine-b"),
      serverClient: client
    )
    await gate.awaitWaiter()
    await controller.setConfigOption("reasoning", "low")
    await gate.release()
    await retarget

    #expect(controller.modelOption?.currentValue == "gpt-5.6-sol")
    #expect(controller.thoughtLevelOptions.first?.currentValue == "low")
    #expect(!controller.draftSnapshot().selectionWasAutomaticallyCarried)
    #expect(defaults.lastHarnessId(forServer: "machine-b") == "codex")
    #expect(
      defaults.configSelections(forHarness: "codex", onServer: "machine-b") == [
        "model": "gpt-5.6-sol", "reasoning": "low",
      ])
  }

  @Test("Restoring a current draft does not promote automatic choices to defaults")
  func restoredCurrentDraftDoesNotReplaceDefaults() {
    let defaults = ComposerDefaultsStore(store: InMemoryStore())
    defaults.rememberHarnessSelection(serverId: "machine-b", harnessId: "claude-code")
    defaults.rememberConfigSelections(
      serverId: "machine-b",
      harnessId: "claude-code",
      configValues: ["model": "fable", "reasoning": "low"]
    )
    let controller = SessionController(
      project: project(serverId: "machine-b"),
      configCache: ConfigOptionCache(store: InMemoryStore()),
      composerDefaults: defaults
    )

    controller.restoreDraft(
      ComposerDraftStore.Draft(
        projectId: controller.project.id,
        projectServerId: "machine-b",
        selectedHarnessId: "codex",
        configByHarness: [
          "codex": ["model": "gpt-5.6-sol", "reasoning": "xhigh"]
        ]
      )
    )

    #expect(defaults.lastHarnessId(forServer: "machine-b") == "claude-code")
    #expect(
      defaults.configSelections(forHarness: "claude-code", onServer: "machine-b") == [
        "model": "fable", "reasoning": "low",
      ])
    #expect(defaults.configSelections(forHarness: "codex", onServer: "machine-b").isEmpty)
  }

  @Test("A restored automatic carry still falls back when its model disappeared")
  func restoredCarryIsRevalidated() async {
    let defaults = ComposerDefaultsStore(store: InMemoryStore())
    defaults.rememberHarnessSelection(serverId: "machine-b", harnessId: "claude-code")
    defaults.rememberConfigSelections(
      serverId: "machine-b",
      harnessId: "claude-code",
      configValues: ["model": "fable", "reasoning": "low"]
    )
    let destinationClaude = capability(
      harnessId: "claude-code",
      currentModel: "fable",
      models: ["fable"],
      currentReasoning: "low",
      reasoning: ["low"]
    )
    let destinationCodex = capability(
      harnessId: "codex",
      currentModel: "gpt-5.5",
      models: ["gpt-5.5"],
      currentReasoning: "high",
      reasoning: ["high"]
    )
    let client = SyncFakeServerClient(projects: [], sessions: [])
    client.capabilitiesHandler = { _ in
      ServerCapabilities(harnesses: [destinationClaude, destinationCodex])
    }
    let controller = SessionController(
      project: project(serverId: "machine-b"),
      configCache: ConfigOptionCache(store: InMemoryStore()),
      composerDefaults: defaults,
      serverClient: client
    )
    controller.restoreDraft(
      ComposerDraftStore.Draft(
        projectId: controller.project.id,
        projectServerId: "machine-b",
        selectedHarnessId: "codex",
        configByHarness: [
          "codex": ["model": "gpt-5.6-sol", "reasoning": "xhigh"]
        ],
        selectionWasAutomaticallyCarried: true
      )
    )

    await controller.prepare()

    #expect(controller.selectedHarnessId == "claude-code")
    #expect(controller.modelOption?.currentValue == "fable")
    #expect(controller.thoughtLevelOptions.first?.currentValue == "low")
    #expect(!controller.draftSnapshot().selectionWasAutomaticallyCarried)
  }

  private func project(serverId: String) -> Project {
    Project.fromFolder(
      URL(fileURLWithPath: "/tmp/\(serverId)"),
      serverId: serverId
    )
  }

  private func capability(
    harnessId: String,
    currentModel: String,
    models: [String],
    currentReasoning: String,
    reasoning: [String]
  ) -> ServerHarnessCapability {
    ServerHarnessCapability(
      harness: ServerHarness(
        id: harnessId,
        name: harnessId == "codex" ? "Codex" : "Claude Code",
        symbolName: "sparkle",
        source: "registry",
        launchKind: "executable",
        enabled: true,
        readiness: ServerHarnessReadiness(state: "ready", detail: nil)
      ),
      modes: nil,
      configOptions: [
        SessionConfigOption(
          id: "model",
          name: "Model",
          category: SessionConfigOption.Category.model,
          currentValue: currentModel,
          options: models.map {
            SessionConfigSelectOption(value: $0, name: $0)
          }
        ),
        SessionConfigOption(
          id: "reasoning",
          name: "Reasoning",
          category: SessionConfigOption.Category.thoughtLevel,
          currentValue: currentReasoning,
          options: reasoning.map {
            SessionConfigSelectOption(value: $0, name: $0)
          }
        ),
      ],
      supportsGoals: false
    )
  }
}
