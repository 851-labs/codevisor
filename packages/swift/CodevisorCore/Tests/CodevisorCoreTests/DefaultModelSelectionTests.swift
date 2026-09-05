import ACPKit
import Foundation
import Testing
import CodevisorTestSupport

@testable import CodevisorCore

/// A draft composer must never render an empty model chip: with options
/// available but no usable current choice, the first option becomes the
/// pending selection — exactly what the send would use.
@MainActor
@Suite("DefaultModelSelection")
struct DefaultModelSelectionTests {
  @Test("A project-less draft loads capabilities using the server fallback directory")
  func placeholderDraftLoadsCapabilities() async {
    let client = SyncFakeServerClient(projects: [], sessions: [])
    client.capabilitiesHandler = { cwd in
      guard cwd.isEmpty else { throw CancellationError() }
      return ServerCapabilities(harnesses: [])
    }
    let controller = SessionController(
      project: .runTargetPlaceholder(serverId: "machine-a"),
      configCache: ConfigOptionCache(store: InMemoryStore()),
      serverClient: client
    )

    await controller.prepare()

    #expect(controller.preparationState == .ready)
  }

  @Test("A draft with no usable model choice pends the first option")
  func defaultsToFirstModel() throws {
    let controller = SessionController.preview()
    let harnessId = try #require(controller.selectedHarnessId)
    controller.configOptionsByHarness[harnessId] = [
      SessionConfigOption(
        id: "model",
        name: "Model",
        category: SessionConfigOption.Category.model,
        currentValue: "",
        options: [
          SessionConfigSelectOption(value: "gpt-x", name: "GPT X"),
          SessionConfigSelectOption(value: "gpt-y", name: "GPT Y"),
        ]
      )
    ]
    controller.ensureDefaultModelSelection()
    #expect(controller.modelOption?.currentValue == "gpt-x")

    // An existing valid (pending) choice is never overridden.
    controller.pendingConfigByHarness[harnessId] = ["model": "gpt-y"]
    controller.ensureDefaultModelSelection()
    #expect(controller.modelOption?.currentValue == "gpt-y")

    // A harness with no model options stays untouched.
    controller.configOptionsByHarness[harnessId] = []
    controller.pendingConfigByHarness[harnessId] = [:]
    controller.ensureDefaultModelSelection()
    #expect(controller.modelOption == nil)
  }

  @Test("Retargeting to another machine never keeps the old catalog")
  func retargetClearsCatalog() async throws {
    let controller = SessionController.preview()
    let harnessId = try #require(controller.selectedHarnessId)
    controller.configOptionsByHarness[harnessId] = [
      SessionConfigOption(
        id: "model",
        name: "Model",
        category: SessionConfigOption.Category.model,
        currentValue: "old",
        options: [SessionConfigSelectOption(value: "old", name: "Old Machine Model")]
      )
    ]

    var other = Project.fromFolder(URL(fileURLWithPath: "/tmp/elsewhere"))
    other.serverId = "another-machine"
    await controller.retarget(
      to: other,
      serverClient: SyncFakeServerClient(projects: [], sessions: [])
    )
    // The fake client cannot serve capabilities; the point is that the
    // OLD machine's catalog is gone rather than rendering as the new
    // machine's.
    #expect(controller.harnesses.isEmpty)
    #expect(controller.configOptionsByHarness.isEmpty)
    #expect(controller.modelOption == nil)
  }

  @Test("A machine switch carries an available harness, model, and settings")
  func retargetCarriesCompatibleSelection() async {
    let defaults = ComposerDefaultsStore(store: InMemoryStore())
    defaults.rememberHarnessSelection(serverId: "machine-b", harnessId: "claude-code")
    defaults.rememberConfigSelections(
      serverId: "machine-b",
      harnessId: "claude-code",
      configValues: ["model": "fable", "reasoning": "low"]
    )
    defaults.rememberConfigSelections(
      serverId: "machine-b",
      harnessId: "codex",
      configValues: ["model": "gpt-5.5", "reasoning": "high"]
    )

    let sourceCodex = capability(
      harnessId: "codex",
      currentModel: "gpt-5.6-sol",
      models: ["gpt-5.5", "gpt-5.6-sol"],
      currentReasoning: "xhigh",
      reasoning: ["low", "high", "xhigh"]
    )
    let destinationClaude = capability(
      harnessId: "claude-code",
      currentModel: "fable",
      models: ["fable"],
      currentReasoning: "low",
      reasoning: ["low", "high"]
    )
    let destinationCodex = capability(
      harnessId: "codex",
      currentModel: "gpt-5.5",
      models: ["gpt-5.5", "gpt-5.6-sol"],
      currentReasoning: "low",
      reasoning: ["low", "high", "xhigh"]
    )
    let resolvedCodex = capability(
      harnessId: "codex",
      currentModel: "gpt-5.6-sol",
      models: ["gpt-5.5", "gpt-5.6-sol"],
      currentReasoning: "xhigh",
      reasoning: ["low", "high", "xhigh"]
    )
    let client = SyncFakeServerClient(projects: [], sessions: [])
    client.capabilitiesHandler = { _ in
      ServerCapabilities(harnesses: [destinationClaude, destinationCodex])
    }
    client.resolvedCapabilitiesHandler = { _, harnessId, _ in
      ServerCapabilities(harnesses: harnessId == "codex" ? [resolvedCodex] : [])
    }

    let controller = SessionController(
      project: project(serverId: "machine-a"),
      configCache: ConfigOptionCache(store: InMemoryStore()),
      composerDefaults: defaults
    )
    controller.harnesses = [sourceCodex.harness]
    controller.selectedHarnessId = "codex"
    controller.configOptionsByHarness["codex"] = sourceCodex.configOptions
    controller.preparationState = .ready

    await controller.retarget(
      to: project(serverId: "machine-b"),
      serverClient: client
    )

    #expect(controller.selectedHarnessId == "codex")
    #expect(controller.modelOption?.currentValue == "gpt-5.6-sol")
    #expect(controller.thoughtLevelOptions.first?.currentValue == "xhigh")
    // Browsing to the machine does not replace its durable fallback.
    #expect(defaults.lastHarnessId(forServer: "machine-b") == "claude-code")
    #expect(
      defaults.configSelections(forHarness: "codex", onServer: "machine-b") == [
        "model": "gpt-5.5", "reasoning": "high",
      ])
  }

  @Test("An unavailable carried model falls back to that machine's profile")
  func retargetFallsBackToDestinationProfile() async {
    let defaults = ComposerDefaultsStore(store: InMemoryStore())
    defaults.rememberHarnessSelection(serverId: "machine-b", harnessId: "codex")
    defaults.rememberConfigSelections(
      serverId: "machine-b",
      harnessId: "codex",
      configValues: ["model": "gpt-5.5", "reasoning": "high"]
    )

    let sourceCodex = capability(
      harnessId: "codex",
      currentModel: "gpt-5.6-sol",
      models: ["gpt-5.6-sol"],
      currentReasoning: "xhigh",
      reasoning: ["xhigh"]
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
      currentReasoning: "low",
      reasoning: ["low", "high"]
    )
    let client = SyncFakeServerClient(projects: [], sessions: [])
    client.capabilitiesHandler = { _ in
      // Claude being first reproduces the catalog-order regression.
      ServerCapabilities(harnesses: [destinationClaude, destinationCodex])
    }

    let controller = SessionController(
      project: project(serverId: "machine-a"),
      configCache: ConfigOptionCache(store: InMemoryStore()),
      composerDefaults: defaults
    )
    controller.harnesses = [sourceCodex.harness]
    controller.selectedHarnessId = "codex"
    controller.configOptionsByHarness["codex"] = sourceCodex.configOptions

    await controller.retarget(
      to: project(serverId: "machine-b"),
      serverClient: client
    )

    #expect(controller.selectedHarnessId == "codex")
    #expect(controller.modelOption?.currentValue == "gpt-5.5")
    #expect(controller.thoughtLevelOptions.first?.currentValue == "high")
  }

  @Test("Unavailable carried settings use the destination harness profile")
  func retargetReconcilesSettings() async {
    let defaults = ComposerDefaultsStore(store: InMemoryStore())
    defaults.rememberHarnessSelection(serverId: "machine-b", harnessId: "codex")
    defaults.rememberConfigSelections(
      serverId: "machine-b",
      harnessId: "codex",
      configValues: ["model": "gpt-5.6-sol", "reasoning": "high"]
    )

    let sourceCodex = capability(
      harnessId: "codex",
      currentModel: "gpt-5.6-sol",
      models: ["gpt-5.6-sol"],
      currentReasoning: "xhigh",
      reasoning: ["low", "high", "xhigh"]
    )
    let destinationCodex = capability(
      harnessId: "codex",
      currentModel: "gpt-5.6-sol",
      models: ["gpt-5.6-sol"],
      currentReasoning: "low",
      reasoning: ["low", "high"]
    )
    let client = SyncFakeServerClient(projects: [], sessions: [])
    client.capabilitiesHandler = { _ in
      ServerCapabilities(harnesses: [destinationCodex])
    }
    client.resolvedCapabilitiesHandler = { _, _, _ in
      ServerCapabilities(harnesses: [destinationCodex])
    }

    let controller = SessionController(
      project: project(serverId: "machine-a"),
      configCache: ConfigOptionCache(store: InMemoryStore()),
      composerDefaults: defaults
    )
    controller.harnesses = [sourceCodex.harness]
    controller.selectedHarnessId = "codex"
    controller.configOptionsByHarness["codex"] = sourceCodex.configOptions

    await controller.retarget(
      to: project(serverId: "machine-b"),
      serverClient: client
    )

    #expect(controller.selectedHarnessId == "codex")
    #expect(controller.modelOption?.currentValue == "gpt-5.6-sol")
    #expect(controller.thoughtLevelOptions.first?.currentValue == "high")
  }

  @Test("A sign-in-only catalog is settled: refreshes never flicker the spinner")
  func signInOnlyCatalogHoldsSteady() async throws {
    let store = InMemoryStore()
    let cache = ConfigOptionCache(store: store)
    var project = Project.fromFolder(URL(fileURLWithPath: "/tmp/machine-a"))
    project.serverId = "machine-a"
    // The machine has nothing usable — only a fleet-enabled harness
    // waiting on auth.
    let pending = ServerHarnessCapability(
      harness: ServerHarness(
        id: "claude-code",
        name: "Claude Code",
        symbolName: "sparkle",
        source: "registry",
        launchKind: "npx",
        enabled: false,
        readiness: ServerHarnessReadiness(state: "ready", detail: nil)
      ),
      modes: nil,
      configOptions: [],
      supportsGoals: nil
    )
    _ = try await cache.revalidateCapabilities(
      forServer: "machine-a", cwd: "/tmp/machine-a", force: true, fetch: { [pending] })

    let controller = SessionController(project: project, configCache: cache)
    #expect(controller.harnesses.isEmpty)

    // A catalog-revision bump (sync gossip, a dismissed sign-in sheet)
    // marks the draft stale — but "Select a harness" plus sign-in rows
    // is a settled answer, so no blocking state and no spinner.
    controller.invalidateHarnessCapabilities()
    #expect(controller.preparationState == .ready)
    #expect(controller.isRefreshingHarnessCapabilities)
    #expect(!controller.isLoadingModelMenu)

    // A machine with NO knowledge at all still earns the spinner.
    var unknown = Project.fromFolder(URL(fileURLWithPath: "/tmp/machine-b"))
    unknown.serverId = "machine-b"
    let blank = SessionController(project: unknown, configCache: cache)
    blank.invalidateHarnessCapabilities()
    #expect(blank.preparationState == .loading)
    #expect(blank.isLoadingModelMenu)
  }

  @Test("A stale fetch never stores its machine's catalog under the new machine's key")
  func staleFetchCannotPoisonRetargetedCache() async throws {
    let controller = SessionController.preview()
    controller.harnesses = []
    controller.selectedHarnessId = nil

    let gate = FetchGate()
    let slowClient = SyncFakeServerClient(projects: [], sessions: [])
    slowClient.capabilitiesHandler = { _ in
      await gate.wait()
      return ServerCapabilities(harnesses: [
        ServerHarnessCapability(
          harness: ServerHarness(
            id: "claude-code",
            name: "Claude Code",
            symbolName: "sparkle",
            source: "registry",
            launchKind: "npx",
            enabled: true,
            readiness: ServerHarnessReadiness(state: "ready", detail: nil)
          ),
          modes: nil,
          configOptions: [
            SessionConfigOption(
              id: "model",
              name: "Model",
              category: SessionConfigOption.Category.model,
              currentValue: "opus-1m",
              options: [SessionConfigSelectOption(value: "opus-1m", name: "Opus (1M context)")]
            )
          ],
          supportsGoals: nil
        )
      ])
    }
    var machineA = Project.fromFolder(URL(fileURLWithPath: "/tmp/machine-a"))
    machineA.serverId = "machine-a"
    // Retarget to A starts a capability fetch bound to A's client, which
    // we hold open at the gate.
    async let retargetToA: Void = controller.retarget(to: machineA, serverClient: slowClient)
    await gate.awaitWaiter()

    // A second retarget lands while A's fetch is still in flight.
    var machineB = Project.fromFolder(URL(fileURLWithPath: "/tmp/machine-b"))
    machineB.serverId = "machine-b"
    await controller.retarget(
      to: machineB,
      serverClient: SyncFakeServerClient(projects: [], sessions: [])
    )

    await gate.release()
    await retargetToA

    // A's catalog belongs under A's key — and ONLY A's key. Before the
    // fix, the stale task re-read the retargeted project and persisted
    // machine A's harnesses/models as machine B's.
    #expect(controller.configCache.capabilities(forServer: "machine-b").isEmpty)
    #expect(controller.configOptionsByHarness["claude-code"] == nil)
    #expect(controller.modelOption == nil)
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

/// One-shot gate: the fetch parks on `wait()`, the test observes the parked
/// waiter via `awaitWaiter()` and later opens the gate with `release()`.
actor FetchGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var released = false
  private let started = TestSignal()

  func wait() async {
    started.signal()
    if released { return }
    await withCheckedContinuation { self.continuation = $0 }
  }

  func awaitWaiter() async {
    await started.wait()
  }

  func release() {
    released = true
    continuation?.resume()
    continuation = nil
  }
}
