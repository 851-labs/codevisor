import ACPKit
import Foundation
import Testing
import CodevisorTestSupport

@testable import CodevisorCore

@MainActor
@Suite("BotModelSelection")
struct BotModelSelectionTests {
  nonisolated private static let efforts = ["opus": ["low", "high"], "haiku": ["low", "medium"]]

  nonisolated private static func capability(
    harnessId: String,
    selections: [String: String] = [:],
    reportsModel: Bool = true
  ) -> ServerHarnessCapability {
    let model = selections["model"] ?? "opus"
    let efforts = Self.efforts[model] ?? []
    let effort = selections["effort"].flatMap { efforts.contains($0) ? $0 : nil } ?? efforts[0]
    return ServerHarnessCapability(
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
          id: "model", name: "Model", category: SessionConfigOption.Category.model,
          currentValue: reportsModel ? model : "",
          options: ["opus", "haiku"].map { SessionConfigSelectOption(value: $0, name: $0) }
        ),
        SessionConfigOption(
          id: "effort", name: "Effort", category: SessionConfigOption.Category.thoughtLevel,
          currentValue: effort,
          options: efforts.map { SessionConfigSelectOption(value: $0, name: $0) }
        ),
      ]
    )
  }

  private func makeSelection(
    remembered: (harnessId: String, selections: [String: String])?,
    reportsModel: Bool = true
  ) -> (BotModelSelection, SyncFakeServerClient) {
    let client = SyncFakeServerClient(projects: [], sessions: [])
    client.resolvedCapabilitiesHandler = { _, harnessId, selections in
      ServerCapabilities(harnesses: [
        Self.capability(harnessId: harnessId, selections: selections, reportsModel: reportsModel)
      ])
    }
    let cache = ConfigOptionCache(store: InMemoryStore())
    cache.store(
      [Self.capability(harnessId: "codex"), Self.capability(harnessId: "claude-code")],
      forServer: "machine-a"
    )
    let defaults = ComposerDefaultsStore(store: InMemoryStore())
    if let remembered {
      let scope = ComposerDefaultsStore.Scope.newWorkspace(serverId: "machine-a")
      defaults.rememberHarnessSelection(in: scope, harnessId: remembered.harnessId)
      defaults.rememberConfigSelections(
        in: scope, harnessId: remembered.harnessId, configValues: remembered.selections)
    }
    let selection = BotModelSelection(
      serverId: "machine-a", client: client, configCache: cache, composerDefaults: defaults, cwd: "/tmp"
    )
    return (selection, client)
  }

  @Test("New bots start from the machine's remembered harness, model, and effort")
  func seedsRememberedDefaults() async {
    let (selection, _) = makeSelection(
      remembered: ("claude-code", ["model": "haiku", "effort": "medium"])
    )

    await selection.seedDefaults()

    #expect(selection.harnesses.map(\.id) == ["codex", "claude-code"])
    #expect(selection.harnessId == "claude-code")
    #expect(selection.configSelections == ["model": "haiku", "effort": "medium"])
    #expect(selection.parameterOptions.map(\.id) == ["effort"])
  }

  @Test("Without remembered defaults the first harness is chosen")
  func seedsFirstHarness() async {
    let (selection, _) = makeSelection(remembered: nil)

    await selection.seedDefaults()

    #expect(selection.harnessId == "codex")
    #expect(selection.configSelections == ["model": "opus", "effort": "low"])
  }

  @Test("A harness that reports no current model starts on its first listed model")
  func unreportedModelFallsBackToFirst() async {
    let (selection, _) = makeSelection(remembered: nil, reportsModel: false)

    await selection.seedDefaults()

    #expect(selection.modelOption?.currentValue == "opus")
    #expect(selection.configSelections["model"] == "opus")
  }

  @Test("Choosing another model resolves its effort levels and drops an unsupported effort")
  func modelChangeResolvesEffort() async throws {
    let (selection, _) = makeSelection(remembered: ("codex", ["model": "opus", "effort": "high"]))
    await selection.seedDefaults()
    #expect(selection.configSelections == ["model": "opus", "effort": "high"])

    await selection.chooseModel(harnessId: "codex", value: "haiku")

    #expect(selection.configSelections == ["model": "haiku", "effort": "low"])
    let effort = try #require(selection.parameterOptions.first)
    #expect(effort.options.map(\.value) == ["low", "medium"])
    selection.setParameter("effort", value: "medium")
    selection.setParameter("effort", value: "max")
    #expect(selection.configSelections["effort"] == "medium")
  }

  @Test("Switching harness does not carry the previous harness's settings")
  func harnessChangeStartsFresh() async {
    let (selection, _) = makeSelection(remembered: ("codex", ["model": "haiku", "effort": "medium"]))
    await selection.seedDefaults()

    await selection.chooseModel(harnessId: "claude-code", value: "opus")

    #expect(selection.harnessId == "claude-code")
    #expect(selection.configSelections == ["model": "opus", "effort": "low"])
  }
}
