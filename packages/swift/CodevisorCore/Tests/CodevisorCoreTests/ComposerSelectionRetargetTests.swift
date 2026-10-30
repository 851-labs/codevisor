import ACPKit
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Composer selection retargeting")
struct ComposerSelectionRetargetTests {
  @Test("A carried selection takes the destination's resolved settings")
  func carriedSelectionAdoptsResolvedSettings() async {
    let fixture = Fixture(rememberedSelections: ["model": "gpt-5.6-sol", "reasoning": "max", "approval": "auto"])
    let gate = FetchGate()
    fixture.client.resolvedCapabilitiesHandler = { [requests = fixture.requests] _, _, selections in
      requests.record(selections)
      await gate.wait()
      return ServerCapabilities(harnesses: [
        Self.codex(model: "gpt-5.6-sol", reasoning: "medium", reasoningOptions: ["low", "medium", "max"])
      ])
    }

    async let retarget: Void = fixture.retarget()
    await gate.awaitWaiter()
    #expect(fixture.controller.isResolvingModelConfiguration)
    await gate.release()
    await retarget

    #expect(fixture.requests.all == [["approval": "auto", "model": "gpt-5.6-sol", "reasoning": "xhigh"]])
    #expect(!fixture.controller.isResolvingModelConfiguration)
    #expect(fixture.controller.modelOption?.currentValue == "gpt-5.6-sol")
    #expect(fixture.controller.thoughtLevelOptions.first?.currentValue == "max")
    #expect(fixture.controller.draftSnapshot().selectionWasAutomaticallyCarried)
  }

  @Test("A carried model the destination can't apply asks for another model")
  func unappliedCarriedModelIsUnavailable() async {
    let fixture = Fixture()
    fixture.client.resolvedCapabilitiesHandler = { _, _, _ in
      var resolved = Self.codex(model: "gpt-5.6-sol", reasoning: "xhigh")
      resolved.unappliedConfigSelections = ["model": "gpt-5.6-sol"]
      return ServerCapabilities(harnesses: [resolved])
    }

    await fixture.retarget()

    #expect(fixture.controller.modelPickerPresentation.modelChip == .selectModel)
    #expect(
      fixture.controller.modelUnavailableMessage
        == "gpt-5.6-sol is no longer available. Select another model.")
    #expect(!fixture.controller.draftSnapshot().selectionWasAutomaticallyCarried)
  }

  @Test("A failed resolve keeps the carry until the next refresh resolves it")
  func failedResolveRetriesOnRefresh() async {
    let fixture = Fixture()
    let attempts = Requests()
    fixture.client.resolvedCapabilitiesHandler = { _, _, selections in
      attempts.record(selections)
      guard attempts.all.count > 1 else { throw CodevisorServerClientError.httpStatus(503, "") }
      return ServerCapabilities(harnesses: [Self.codex(model: "gpt-5.6-sol", reasoning: "medium")])
    }

    await fixture.retarget()

    #expect(!fixture.controller.isResolvingModelConfiguration)
    #expect(fixture.controller.draftSnapshot().selectionWasAutomaticallyCarried)
    #expect(fixture.controller.thoughtLevelOptions.first?.currentValue != "medium")

    await fixture.controller.refreshHarnessCapabilities()

    #expect(attempts.all.count == 2)
    #expect(fixture.controller.thoughtLevelOptions.first?.currentValue == "medium")
  }

  @Test("Invalidating capabilities mid-resolve discards the stale answer")
  func invalidationDiscardsInFlightResolve() async {
    let fixture = Fixture()
    let gate = FetchGate()
    fixture.client.resolvedCapabilitiesHandler = { _, _, _ in
      await gate.wait()
      return ServerCapabilities(harnesses: [Self.codex(model: "gpt-5.6-sol", reasoning: "medium")])
    }

    async let retarget: Void = fixture.retarget()
    await gate.awaitWaiter()
    fixture.controller.invalidateHarnessCapabilities()
    #expect(!fixture.controller.isResolvingModelConfiguration)
    await gate.release()
    await retarget

    #expect(!fixture.controller.isResolvingModelConfiguration)
    #expect(fixture.controller.thoughtLevelOptions.first?.currentValue != "medium")
  }

  @Test("A carry for a harness that is no longer selected is dropped")
  func carryForDeselectedHarnessIsDropped() async {
    let fixture = Fixture()
    fixture.controller.project = Self.project(serverId: "machine-b")
    fixture.controller.serverClient = fixture.client
    fixture.controller.harnesses = [Self.codex(model: "gpt-5.6-sol", reasoning: "low").harness]
    fixture.controller.selectedHarnessId = "claude-code"
    fixture.controller.automaticSelectionIntent = Self.carriedIntent(modelValue: "gpt-5.6-sol")
    fixture.controller.automaticSelectionNeedsResolution = true

    await fixture.controller.resolveAutomaticSelectionIfNeeded()

    #expect(!fixture.controller.draftSnapshot().selectionWasAutomaticallyCarried)
    #expect(fixture.requests.all.isEmpty)
  }

  @Test("A carried model missing from the destination catalog asks for another model")
  func carriedModelMissingFromCatalogIsUnavailable() async {
    let fixture = Fixture()
    fixture.controller.project = Self.project(serverId: "machine-b")
    fixture.controller.serverClient = fixture.client
    fixture.controller.selectedHarnessId = "codex"
    fixture.controller.configOptionsByHarness["codex"] = Self.codex(model: "gpt-5.5", reasoning: "low").configOptions
    fixture.controller.automaticSelectionIntent = Self.carriedIntent(modelValue: "gpt-5.6-sol")
    fixture.controller.automaticSelectionNeedsResolution = true

    await fixture.controller.resolveAutomaticSelectionIfNeeded()

    #expect(
      fixture.controller.modelUnavailableMessage
        == "gpt-5.6-sol is no longer available. Select another model.")
    #expect(!fixture.controller.draftSnapshot().selectionWasAutomaticallyCarried)
    #expect(fixture.requests.all.isEmpty)
  }

  @Test("A carry without a model needs no resolution")
  func carryWithoutModelSkipsResolution() async {
    let fixture = Fixture()
    fixture.controller.project = Self.project(serverId: "machine-b")
    fixture.controller.serverClient = fixture.client
    fixture.controller.selectedHarnessId = "codex"
    fixture.controller.automaticSelectionIntent = Self.carriedIntent(modelValue: nil)
    fixture.controller.automaticSelectionNeedsResolution = true

    await fixture.controller.resolveAutomaticSelectionIfNeeded()

    #expect(fixture.controller.draftSnapshot().selectionWasAutomaticallyCarried)
    #expect(!fixture.controller.isResolvingModelConfiguration)
    #expect(fixture.requests.all.isEmpty)
  }

  @MainActor
  private final class Fixture {
    let defaults = ComposerDefaultsStore(store: InMemoryStore())
    let client = SyncFakeServerClient(projects: [], sessions: [])
    let requests = Requests()
    let controller: SessionController

    init(rememberedSelections: [String: String] = [:]) {
      defaults.rememberConfigSelections(
        harnessId: "codex", modelOptionId: "model",
        configValues: rememberedSelections
      )
      controller = SessionController(
        project: ComposerSelectionRetargetTests.project(serverId: "machine-a"),
        configCache: ConfigOptionCache(store: InMemoryStore()),
        composerDefaults: defaults
      )
      let source = ComposerSelectionRetargetTests.codex(model: "gpt-5.6-sol", reasoning: "xhigh")
      controller.harnesses = [source.harness]
      controller.selectedHarnessId = "codex"
      controller.configOptionsByHarness["codex"] = source.configOptions
      controller.pendingConfiguration.replaceValues(
        ["model": "gpt-5.6-sol", "reasoning": "xhigh"],
        for: "codex"
      )
      client.capabilitiesHandler = { _ in
        ServerCapabilities(harnesses: [ComposerSelectionRetargetTests.codex(model: "gpt-5.6-sol", reasoning: "low")])
      }
      client.resolvedCapabilitiesHandler = { [requests] _, _, selections in
        requests.record(selections)
        return ServerCapabilities(harnesses: [])
      }
    }

    func retarget() async {
      await controller.retarget(
        to: ComposerSelectionRetargetTests.project(serverId: "machine-b"),
        serverClient: client
      )
    }
  }

  private final class Requests: @unchecked Sendable {
    private let lock = NSLock()
    private var selections: [[String: String]] = []

    var all: [[String: String]] { lock.withLock { selections } }

    func record(_ values: [String: String]) {
      lock.withLock { selections.append(values) }
    }
  }

  private static func carriedIntent(modelValue: String?) -> ComposerSelectionIntent {
    ComposerSelectionIntent(
      harnessId: "codex",
      configValues: ["reasoning": "xhigh"],
      modelValue: modelValue
    )
  }

  private static func project(serverId: String) -> Project {
    Project.fromFolder(URL(fileURLWithPath: "/tmp/\(serverId)"), serverId: serverId)
  }

  nonisolated private static func codex(
    model: String,
    reasoning: String,
    reasoningOptions: [String] = ["low", "medium", "xhigh"]
  ) -> ServerHarnessCapability {
    ServerHarnessCapability(
      harness: ServerHarness(
        id: "codex",
        name: "Codex",
        symbolName: "sparkle",
        source: "registry",
        launchKind: "executable",
        enabled: true,
        readiness: ServerHarnessReadiness(state: "ready", detail: nil)
      ),
      configOptions: [
        SessionConfigOption(
          id: "model",
          name: "Model",
          category: SessionConfigOption.Category.model,
          currentValue: model,
          options: [SessionConfigSelectOption(value: model, name: model)]
        ),
        SessionConfigOption(
          id: "reasoning",
          name: "Reasoning",
          category: SessionConfigOption.Category.thoughtLevel,
          currentValue: reasoning,
          options: reasoningOptions.map { SessionConfigSelectOption(value: $0, name: $0) }
        ),
        SessionConfigOption(
          id: "approval",
          name: "Approval",
          currentValue: "ask",
          options: ["ask", "auto"].map { SessionConfigSelectOption(value: $0, name: $0) }
        ),
      ],
      supportsGoals: false
    )
  }
}
