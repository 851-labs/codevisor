import ACPKit
import Foundation
import Testing

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
}

/// One-shot gate: the fetch parks on `wait()`, the test observes the parked
/// waiter via `awaitWaiter()` and later opens the gate with `release()`.
actor FetchGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var hasWaiter = false

    func wait() async {
        hasWaiter = true
        if released { return }
        await withCheckedContinuation { self.continuation = $0 }
    }

    func awaitWaiter() async {
        while !hasWaiter { await Task.yield() }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
