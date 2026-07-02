import Foundation
import Observation
import HerdManCore
import ACPKit

/// The facade for a session screen. Holds the composer text and harness
/// selection, connects the session through the HerdMan server on first send,
/// then forwards to the live `SessionModel`.
@MainActor
@Observable
final class SessionController {
    enum Status: Equatable {
        case idle
        case connecting(String)
        case failed(String)
    }

    var composerText: String = ""
    private(set) var harnesses: [ServerHarness] = []
    var selectedHarnessId: String?
    private(set) var model: SessionModel?
    private(set) var status: Status = .idle

    /// The project whose folder is used as the agent cwd. Settable so the
    /// new-chat page can change projects before the first send.
    var project: Project
    /// Called once, on the first send — used by the new-chat page to create and
    /// register the real session and navigate to it.
    var onFirstSend: (() -> Void)?

    /// The agent session to resume (existing session); nil for a brand-new chat.
    var resumeAgentSessionId: String?
    /// The durable HerdMan session mirrored by the server. Nil for a draft until first send.
    var serverSession: ChatSession?
    /// When true, the draft runs in a new git worktree created on the first
    /// send. Until the worktree exists there is no cwd to connect with, so the
    /// eager pre-connect is skipped.
    var wantsNewWorktree = false
    /// The worktree created for this draft on first send (server-assigned slug).
    private(set) var worktreeName: String?
    /// The created worktree's path; overrides the project folder as the agent cwd.
    private(set) var sessionCwdOverride: String?
    /// Called with the agent session id once a brand-new session is created.
    var onAgentSessionCreated: ((String) -> Void)?
    /// The agent session id currently connected (resumed or newly created).
    private(set) var connectedAgentSessionId: String?

    private let configCache: ConfigOptionCache
    private let settings: AppSettingsModel?
    private let serverClient: (any HerdManServerClienting)?
    private var hasSentFirst = false
    private var connectedHarnessId: String?
    /// Config changes made before connecting, applied once the agent connects.
    private var pendingConfig: [String: String] = [:]
    private var pendingModeId: String?
    private var modeStateByHarness: [String: SessionModeState] = [:]
    private var configOptionsByHarness: [String: [SessionConfigOption]] = [:]

    init(
        project: Project,
        configCache: ConfigOptionCache,
        settings: AppSettingsModel? = nil,
        serverClient: (any HerdManServerClienting)? = nil
    ) {
        self.project = project
        self.configCache = configCache
        self.settings = settings
        self.serverClient = serverClient
        seedFromCachedServerCapabilities()
    }

    var isPrepared: Bool { !harnesses.isEmpty }

    /// The directory the agent runs in: the session's server-resolved cwd
    /// (project folder or worktree), a just-created worktree, or the project
    /// folder for plain drafts.
    var sessionCwdURL: URL {
        if let cwd = serverSession?.cwd { return URL(fileURLWithPath: cwd) }
        if let sessionCwdOverride { return URL(fileURLWithPath: sessionCwdOverride) }
        return project.folderURL
    }

    // MARK: - Derived state

    var conversation: [ConversationItem] { model?.conversation ?? [] }
    var queuedPrompts: [ServerPromptQueueItem] { model?.queuedPrompts ?? [] }
    var availableCommands: [AvailableCommand] { model?.availableCommands ?? [] }
    var isConnected: Bool { model != nil }
    var modeState: SessionModeState? {
        if let model { return model.modeState }
        guard let selectedHarnessId, var state = modeStateByHarness[selectedHarnessId] else { return nil }
        if let pendingModeId { state.currentModeId = pendingModeId }
        return state
    }
    var errorMessage: String? { model?.errorMessage }
    var usage: SessionUsage? { model?.usage }

    /// Selectable config options: live when connected, otherwise the cached
    /// (stale) options for the selected harness with any pending edits applied.
    var configOptions: [SessionConfigOption] {
        if let model { return model.configOptions }
        guard let harnessId = selectedHarnessId else { return [] }
        return (configOptionsByHarness[harnessId] ?? configCache.options(forHarness: harnessId)).map { option in
            guard let pending = pendingConfig[option.id] else { return option }
            var updated = option
            updated.currentValue = pending
            return updated
        }
    }

    /// The config options shown as composer pickers, in a sensible order.
    var pickerOptions: [SessionConfigOption] {
        let order = [
            SessionConfigOption.Category.model,
            SessionConfigOption.Category.thoughtLevel,
            SessionConfigOption.Category.modelConfig,
            SessionConfigOption.Category.mode
        ]
        return configOptions
            .filter { !$0.options.isEmpty }
            .sorted { left, right in
                let leftIndex = order.firstIndex(of: left.category ?? "") ?? 99
                let rightIndex = order.firstIndex(of: right.category ?? "") ?? 99
                if leftIndex == rightIndex { return left.name < right.name }
                return leftIndex < rightIndex
            }
    }

    var hasModeConfigPicker: Bool {
        pickerOptions.contains { option in
            option.category == SessionConfigOption.Category.mode || option.id == "mode"
        }
    }

    func setConfigOption(_ configId: String, _ value: String) async {
        if let model {
            await model.setConfigOption(configId: configId, value: value)
            if let harnessId = connectedHarnessId {
                configCache.store(model.configOptions, forHarness: harnessId)
                configOptionsByHarness[harnessId] = model.configOptions
            }
        } else {
            // Not connected yet: remember it and apply on connect.
            pendingConfig[configId] = value
            if let harnessId = selectedHarnessId {
                var options = configOptionsByHarness[harnessId] ?? configCache.options(forHarness: harnessId)
                if let index = options.firstIndex(where: { $0.id == configId }) {
                    options[index].currentValue = value
                    configOptionsByHarness[harnessId] = options
                }
            }
        }
    }

    var selectedHarness: ServerHarness? {
        harnesses.first { $0.id == selectedHarnessId }
    }

    var isConnecting: Bool {
        if case .connecting = status { return true }
        return false
    }

    /// Whether the session is actively generating a response.
    var isSending: Bool { model?.isSending ?? false }

    var isBusy: Bool {
        isConnecting || isSending
    }

    var canSend: Bool {
        !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isConnecting
            && (isConnected || selectedHarness != nil)
    }

    // MARK: - Actions

    /// Loads the harness list for the picker from the server (cached
    /// capabilities first for instant display, then a live refresh). For a new
    /// chat the list honors the user's enabled set (falling back to all ready
    /// harnesses if they've disabled everything); a resumed session always
    /// keeps its own harness.
    func prepare() async {
        guard let serverClient else { return }
        if seedFromCachedServerCapabilities() {
            Task { await self.prepareFromServerCapabilities(serverClient) }
            return
        }
        _ = await prepareFromServerCapabilities(serverClient)
    }

    /// Eagerly connects the selected harness (without sending) so model and
    /// reasoning config options are available in the composer before the first
    /// message. Safe to call repeatedly.
    func connectIfNeeded() async {
        guard model == nil, !isConnecting, let harness = selectedHarness else { return }
        // A worktree draft has no cwd until the worktree is created on first
        // send; connecting now would pin the agent to the project folder.
        guard !wantsNewWorktree || sessionCwdOverride != nil else { return }
        guard serverSession != nil else { return }
        status = .connecting("Starting \(harness.name)…")
        do {
            model = try await connect(harness)
            status = .idle
        } catch {
            status = .failed(serverErrorMessage(error))
        }
    }

    /// Selects a different harness (user action) and reconnects.
    func selectHarness(_ id: String) async {
        guard id != selectedHarnessId else { return }
        selectedHarnessId = id
        if var serverSession {
            serverSession.harnessId = id
            self.serverSession = serverSession
        }
        await reconnect()
    }

    /// Changes the project (user action) and reconnects.
    func selectProject(_ project: Project) async {
        guard project.id != self.project.id else { return }
        self.project = project
        seedFromCachedServerCapabilities()
        await reconnect()
    }

    /// Tears down any connection and reconnects — used when the harness or
    /// project changes on the new-chat page.
    func reconnect() async {
        model = nil
        status = .idle
        await connectIfNeeded()
    }

    /// Sends the composer text, connecting the harness first if needed.
    func send() async {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isConnecting else { return }

        // Materialize the worktree before the session record or agent exist,
        // so both are born with the worktree cwd.
        if wantsNewWorktree, sessionCwdOverride == nil {
            guard await createWorktree() else { return }
        }

        if !hasSentFirst {
            hasSentFirst = true
            onFirstSend?()
            onFirstSend = nil
        }

        // Clear before any await: the session page reuses this controller, and
        // the sent text lingering in the composer next to the optimistic user
        // message reads as a duplicate. Failure paths restore it.
        composerText = ""

        if let model {
            await model.send(text)
            return
        }

        guard let harness = selectedHarness else {
            status = .failed("No agent is installed. Install Claude Code or Codex and try again.")
            composerText = text
            return
        }
        status = .connecting("Starting \(harness.name)…")
        do {
            let model = try await connect(harness)
            self.model = model
            status = .idle
            await model.send(text)
        } catch {
            status = .failed(serverErrorMessage(error))
            composerText = text
        }
    }

    /// Asks the server to create a git worktree for this draft. The server
    /// owns the fixed location (~/herdman/{projectId}/{name}) and picks a
    /// random memorable name ("ferocious-walrus"); the app never computes
    /// either. Returns false on failure, leaving a status the composer surfaces.
    private func createWorktree() async -> Bool {
        guard let serverClient else {
            status = .failed("Worktrees need the HerdMan server. Start it and try again.")
            return false
        }
        status = .connecting("Creating worktree…")
        do {
            let worktree = try await serverClient.createWorktree(
                projectId: project.id,
                name: nil
            )
            sessionCwdOverride = worktree.path
            worktreeName = worktree.name
            status = .idle
            return true
        } catch let HerdManServerClientError.httpStatus(_, message) {
            status = .failed(worktreeFailureMessage(from: message))
            return false
        } catch {
            status = .failed(serverErrorMessage(error))
            return false
        }
    }

    private func worktreeFailureMessage(from body: String) -> String {
        guard let data = body.data(using: .utf8),
              let payload = try? JSONDecoder().decode([String: String].self, from: data),
              let error = payload["error"] else {
            return body.isEmpty ? "Could not create the worktree." : body
        }
        return error
    }

    func stop() async {
        await model?.cancel()
    }

    func updateQueuedPrompt(id: String, text: String) async {
        await model?.updateQueuedPrompt(id: id, text: text)
    }

    func deleteQueuedPrompt(id: String) async {
        await model?.deleteQueuedPrompt(id: id)
    }

    func setMode(_ modeId: String) async {
        if let model {
            await model.setMode(modeId)
        } else {
            pendingModeId = modeId
        }
    }

    func retry() async {
        status = .idle
        await prepare()
    }

    // MARK: - Connection

    private func connect(_ harness: ServerHarness) async throws -> SessionModel {
        guard let serverClient, var serverSession else {
            throw SessionControllerError.serverUnavailable
        }
        return try await connectServerSession(harness, serverClient: serverClient, session: &serverSession)
    }

    private func connectServerSession(
        _ harness: ServerHarness,
        serverClient: any HerdManServerClienting,
        session: inout ChatSession
    ) async throws -> SessionModel {
        if session.harnessId.isEmpty {
            session.harnessId = harness.id
        }
        if session.agentSessionId == nil, let resumeAgentSessionId {
            session.agentSessionId = resumeAgentSessionId
        }

        _ = try await serverClient.upsertProject(project)
        let remoteSession = try await serverClient.upsertSession(session)
        session = try remoteSession.chatSession()
        self.serverSession = session

        connectedHarnessId = harness.id
        if let agentSessionId = session.agentSessionId {
            connectedAgentSessionId = agentSessionId
            onAgentSessionCreated?(agentSessionId)
        }

        let transport = ServerSessionTransport(client: serverClient, sessionId: session.id)
        let model = SessionModel(
            serverTransport: transport,
            sessionId: session.id.uuidString,
            modeState: modeStateByHarness[harness.id],
            configOptions: configOptionsByHarness[harness.id] ?? configCache.options(forHarness: harness.id)
        )
        if resumeAgentSessionId != nil {
            await model.loadHistory()
        }

        if let pendingModeId {
            await model.setMode(pendingModeId)
        }
        pendingModeId = nil

        for (configId, value) in pendingConfig {
            await model.setConfigOption(configId: configId, value: value)
        }
        pendingConfig.removeAll()

        configCache.store(model.configOptions, forHarness: harness.id)
        configOptionsByHarness[harness.id] = model.configOptions
        return model
    }

    @discardableResult
    private func prepareFromServerCapabilities(_ serverClient: any HerdManServerClienting) async -> Bool {
        do {
            let response = try await serverClient.capabilities(cwd: project.folderURL.path)
            let capabilities = response.harnesses.filter { capability in
                capability.harness.enabled && capability.harness.isReady
            }
            applyHarnessCapabilities(capabilities)
            for capability in capabilities {
                configCache.store(capability.configOptions, forHarness: capability.harness.id)
            }
            configCache.store(capabilities, forServer: project.serverId)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    private func seedFromCachedServerCapabilities() -> Bool {
        guard serverClient != nil else { return false }
        let cached = configCache.capabilities(forServer: project.serverId).filter { capability in
            capability.harness.enabled && capability.harness.isReady
        }
        guard !cached.isEmpty else { return false }
        applyHarnessCapabilities(cached)
        return true
    }

    private func applyHarnessCapabilities(_ capabilities: [ServerHarnessCapability]) {
        let available = capabilities.map(\.harness)
        let isNewChat = resumeAgentSessionId == nil
        if let settings, isNewChat {
            let enabled = available.filter { settings.isHarnessEnabled($0.id) }
            harnesses = enabled.isEmpty ? available : enabled
        } else {
            harnesses = available
        }
        for capability in capabilities {
            configOptionsByHarness[capability.harness.id] = capability.configOptions
            if let modes = capability.modes {
                modeStateByHarness[capability.harness.id] = modes
            }
        }
        if isNewChat {
            if selectedHarnessId == nil || !harnesses.contains(where: { $0.id == selectedHarnessId }) {
                selectedHarnessId = harnesses.first?.id
            }
        } else if selectedHarnessId == nil {
            selectedHarnessId = harnesses.first?.id
        }
    }
}

enum SessionControllerError: Error {
    /// Sessions run through the HerdMan server; without it there is nothing to
    /// connect to.
    case serverUnavailable
}

#if DEBUG
extension SessionController {
    /// A controller pre-populated for previews.
    static func preview(
        project: Project = Project.fromFolder(URL(fileURLWithPath: "/tmp/shepherd")),
        model: SessionModel? = nil,
        harnesses: [ServerHarness] = SessionController.previewHarnesses
    ) -> SessionController {
        let controller = SessionController(
            project: project,
            configCache: ConfigOptionCache(store: InMemoryStore())
        )
        controller.harnesses = harnesses
        controller.selectedHarnessId = harnesses.first?.id
        controller.model = model
        return controller
    }

    nonisolated static var previewHarnesses: [ServerHarness] {
        [
            ServerHarness(
                id: "claude-code", name: "Claude Code", symbolName: "sparkle", source: "registry",
                launchKind: "executable", enabled: true,
                readiness: ServerHarnessReadiness(state: "ready")
            ),
            ServerHarness(
                id: "codex", name: "Codex", symbolName: "chevron.left.forwardslash.chevron.right",
                source: "registry", launchKind: "executable", enabled: true,
                readiness: ServerHarnessReadiness(state: "ready")
            )
        ]
    }
}
#endif
