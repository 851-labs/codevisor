import Foundation
import Testing
import ACPKit
@testable import CodevisorCore

@MainActor
@Suite("SessionController configuration")
struct SessionControllerConfigurationTests {
    @Test("An in-flight capability refresh keeps a provisional catalog loading")
    func provisionalCatalogKeepsModelLoading() {
        let cache = ConfigOptionCache(store: InMemoryStore())
        let capability = capability(model: "gpt-5.6")
        let controller = SessionController(
            project: Project.fromFolder(URL(fileURLWithPath: "/tmp/project")),
            configCache: cache
        )
        controller.harnesses = [capability.harness]
        controller.selectedHarnessId = capability.harness.id
        controller.preparationState = .ready
        controller.isRefreshingHarnessCapabilities = true

        #expect(controller.isRefreshingHarnessCapabilities)
        #expect(controller.isLoadingModelMenu)
        #expect(!controller.hasModelMenu)
    }

    @Test("Catalog invalidation keeps a mounted draft usable during refresh")
    func invalidationPreservesMountedDraft() {
        let cache = ConfigOptionCache(store: InMemoryStore())
        let capability = capability(model: "stale-model")
        let controller = SessionController(
            project: Project.fromFolder(URL(fileURLWithPath: "/tmp/project")),
            configCache: cache
        )
        controller.harnesses = [capability.harness]
        controller.selectedHarnessId = capability.harness.id
        controller.configOptionsByHarness[capability.harness.id] = capability.configOptions
        controller.modeStateByHarness[capability.harness.id] = SessionModeState(
            currentModeId: "default",
            availableModes: [SessionMode(id: "default", name: "Default")]
        )
        controller.supportsGoalsByHarness[capability.harness.id] = true
        controller.preparationState = .ready

        #expect(controller.hasModelMenu)
        controller.invalidateHarnessCapabilities()

        #expect(controller.harnesses == [capability.harness])
        #expect(controller.configOptions == capability.configOptions)
        #expect(controller.modeState?.currentModeId == "default")
        #expect(controller.supportsGoals)
        #expect(controller.preparationState == .ready)
        #expect(controller.isRefreshingHarnessCapabilities)
        #expect(!controller.isLoadingModelMenu)
    }

    @Test("Remote attention metadata does not republish the controller session")
    func ignoresPresentationOnlySessionUpdates() {
        let original = session()
        let controller = controller(for: original)
        var attentionUpdate = original
        attentionUpdate.title = "Renamed remotely"
        attentionUpdate.origin = .imported
        attentionUpdate.isArchived = true
        attentionUpdate.archivedAt = Date(timeIntervalSince1970: 200)
        attentionUpdate.createdAt = Date(timeIntervalSince1970: 100)
        attentionUpdate.updatedAt = Date(timeIntervalSince1970: 300)
        attentionUpdate.sidebarState = .waitingForUser
        attentionUpdate.sidebarStateChangedAt = Date(timeIntervalSince1970: 300)
        attentionUpdate.latestAttentionSequence = 8
        attentionUpdate.lastSeenAttentionSequence = 3
        attentionUpdate.unreadCount = 5
        attentionUpdate.hasUnreadError = true
        attentionUpdate.actionRequired = true
        attentionUpdate.actionRequiredKind = "approval"
        attentionUpdate.pendingPlanApproval = true

        #expect(!controller.reconcileExistingSession(attentionUpdate))
        #expect(controller.serverSession == original)
    }

    @Test("Remote runtime changes are adopted by the controller")
    func adoptsRuntimeSessionUpdates() {
        let original = session()
        let updates: [(inout ChatSession) -> Void] = [
            { $0.id = UUID() },
            { $0.projectId = UUID() },
            { $0.serverId = "remote-b" },
            { $0.harnessId = "claude-code" },
            { $0.harnessAccountId = "work" },
            { $0.agentSessionId = "agent-2" },
            { $0.worktreeName = "fix/crash" },
            { $0.cwd = "/remote/project-worktree" },
            { $0.configSelections = ["model": "gpt-5.6"] },
        ]

        for update in updates {
            let controller = controller(for: original)
            var changed = original
            update(&changed)

            #expect(controller.reconcileExistingSession(changed))
            #expect(controller.serverSession == changed)
        }
    }

    @Test("Reconciliation configures an unbound controller")
    func configuresUnboundController() {
        let session = session()
        let project = Project.fromFolder(
            URL(fileURLWithPath: "/remote/project"),
            id: session.projectId,
            serverId: session.serverId
        )
        let controller = SessionController(
            project: project,
            configCache: ConfigOptionCache(store: InMemoryStore())
        )

        #expect(controller.reconcileExistingSession(session))
        #expect(controller.serverSession == session)
        #expect(controller.selectedHarnessId == session.harnessId)
    }

    @Test("A deferred durable chat cannot connect before first send")
    func deferredChatDoesNotConnect() async {
        var deferred = session()
        deferred.agentSessionId = ""
        let project = Project.fromFolder(
            URL(fileURLWithPath: "/remote/project"),
            id: deferred.projectId,
            serverId: deferred.serverId
        )
        let controller = SessionController(
            project: project,
            configCache: ConfigOptionCache(store: InMemoryStore()),
            serverClient: FakeSessionServerClient(sessionId: deferred.id)
        )
        controller.configureExistingSession(deferred)

        await controller.connectIfNeeded()

        #expect(controller.model == nil)
        #expect(!controller.isConnecting)
        #expect(controller.connectedAgentSessionId == nil)
    }

    private func controller(for session: ChatSession) -> SessionController {
        let project = Project.fromFolder(
            URL(fileURLWithPath: "/remote/project"),
            id: session.projectId,
            serverId: session.serverId
        )
        let controller = SessionController(
            project: project,
            configCache: ConfigOptionCache(store: InMemoryStore())
        )
        controller.configureExistingSession(session)
        return controller
    }

    private func session() -> ChatSession {
        ChatSession(
            projectId: UUID(),
            serverId: "remote-a",
            harnessId: "codex",
            harnessAccountId: "personal",
            agentSessionId: "agent-1",
            title: "Remote chat",
            worktreeName: nil,
            cwd: "/remote/project",
            configSelections: ["model": "gpt-5.5"],
            createdAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func capability(model: String) -> ServerHarnessCapability {
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
                    currentValue: model,
                    options: [SessionConfigSelectOption(value: model, name: model)]
                )
            ],
            supportsGoals: false
        )
    }
}
