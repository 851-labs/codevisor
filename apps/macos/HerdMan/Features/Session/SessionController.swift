import Foundation
import Observation
import HerdManCore
import ACPKit
import ACPAgents

/// The facade for a session screen. Holds the composer text and harness
/// selection, lazily launches the chosen harness on first send, then forwards
/// to the live `SessionModel`.
@MainActor
@Observable
final class SessionController {
    enum Status: Equatable {
        case idle
        case connecting(String)
        case failed(String)
    }

    var composerText: String = ""
    private(set) var harnesses: [DiscoveredAgent] = []
    var selectedHarnessId: String?
    private(set) var model: SessionModel?
    private(set) var status: Status = .idle

    /// The workspace whose folder is used as the agent cwd. Settable so the
    /// new-chat page can change projects before the first send.
    var workspace: Workspace
    /// Called once, on the first send — used by the new-chat page to create and
    /// register the real session and navigate to it.
    var onFirstSend: (() -> Void)?

    /// The agent session to resume (existing session); nil for a brand-new chat.
    var resumeAgentSessionId: String?
    /// The durable HerdMan session mirrored by the server. Nil for a draft until first send.
    var serverSession: ChatSession?
    /// Called with the agent session id once a brand-new session is created.
    var onAgentSessionCreated: ((String) -> Void)?
    /// The agent session id currently connected (resumed or newly created).
    private(set) var connectedAgentSessionId: String?

    private let agentService: any AgentServicing
    private let configCache: ConfigOptionCache
    private let settings: AppSettingsModel?
    private var delegate: AppClientDelegate?
    private var client: ACPClient?
    private let serverClient: (any HerdManServerClienting)?
    private var hasSentFirst = false
    private var connectedHarnessId: String?
    /// Config changes made before connecting, applied once the agent connects.
    private var pendingConfig: [String: String] = [:]
    private var pendingModeId: String?
    private var modeStateByHarness: [String: SessionModeState] = [:]
    private var configOptionsByHarness: [String: [SessionConfigOption]] = [:]

    init(
        workspace: Workspace,
        agentService: any AgentServicing,
        configCache: ConfigOptionCache,
        settings: AppSettingsModel? = nil,
        serverClient: (any HerdManServerClienting)? = nil
    ) {
        self.workspace = workspace
        self.agentService = agentService
        self.configCache = configCache
        self.settings = settings
        self.serverClient = serverClient
        seedFromCachedServerCapabilities()
    }

    var isPrepared: Bool { !harnesses.isEmpty }

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

    var selectedHarness: DiscoveredAgent? {
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

    /// Discovers installed harnesses for the picker. For a new chat the list
    /// honors the user's enabled set (falling back to all installed if they've
    /// disabled everything); a resumed session always keeps its own harness.
    func prepare() async {
        if let serverClient {
            if seedFromCachedServerCapabilities() {
                Task { await self.prepareFromServerCapabilities(serverClient) }
                return
            }
            if await prepareFromServerCapabilities(serverClient) {
                return
            }
        }

        let installed = await agentService.discoverAgents()
        let isNewChat = resumeAgentSessionId == nil
        if let settings, isNewChat {
            let enabled = installed.filter { settings.isHarnessEnabled($0.id) }
            harnesses = enabled.isEmpty ? installed : enabled
        } else {
            harnesses = installed
        }
        if isNewChat {
            if selectedHarnessId == nil || !harnesses.contains(where: { $0.id == selectedHarnessId }) {
                selectedHarnessId = harnesses.first?.id
            }
        } else if selectedHarnessId == nil {
            selectedHarnessId = harnesses.first?.id
        }
    }

    /// Eagerly connects the selected harness (without sending) so model and
    /// reasoning config options are available in the composer before the first
    /// message. Safe to call repeatedly.
    func connectIfNeeded() async {
        guard model == nil, !isConnecting, let harness = selectedHarness else { return }
        guard serverClient == nil || serverSession != nil else { return }
        status = .connecting("Starting \(harness.name)…")
        do {
            model = try await connect(harness)
            status = .idle
        } catch {
            status = .failed(String(describing: error))
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

    /// Changes the project/workspace (user action) and reconnects.
    func selectWorkspace(_ workspace: Workspace) async {
        guard workspace.id != self.workspace.id else { return }
        self.workspace = workspace
        seedFromCachedServerCapabilities()
        await reconnect()
    }

    /// Tears down any connection and reconnects — used when the harness or
    /// project changes on the new-chat page.
    func reconnect() async {
        await client?.close()
        client = nil
        delegate = nil
        model = nil
        status = .idle
        await connectIfNeeded()
    }

    /// Sends the composer text, connecting the harness first if needed.
    func send() async {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isConnecting else { return }

        if !hasSentFirst {
            hasSentFirst = true
            onFirstSend?()
            onFirstSend = nil
        }

        if let model {
            composerText = ""
            await model.send(text)
            return
        }

        guard let harness = selectedHarness else {
            status = .failed("No agent is installed. Install Claude Code or Codex and try again.")
            return
        }
        status = .connecting("Starting \(harness.name)…")
        do {
            let model = try await connect(harness)
            self.model = model
            status = .idle
            composerText = ""
            await model.send(text)
        } catch {
            status = .failed(String(describing: error))
        }
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

    func shutdown() async {
        await client?.close()
    }

    // MARK: - Connection

    private func connect(_ harness: DiscoveredAgent) async throws -> SessionModel {
        if let serverClient, var serverSession {
            return try await connectServerSession(harness, serverClient: serverClient, session: &serverSession)
        }

        let delegate = AppClientDelegate()
        self.delegate = delegate
        let client = try await agentService.launch(
            harness,
            workingDirectory: workspace.folderURL,
            delegate: delegate
        )
        self.client = client

        _ = try await client.initialize(InitializeRequest(
            protocolVersion: .acpProtocolVersion,
            clientCapabilities: ClientCapabilities(
                fs: FileSystemCapabilities(readTextFile: true, writeTextFile: true),
                plan: true
            ),
            clientInfo: Implementation(name: "HerdMan", version: "1.0")
        ))
        connectedHarnessId = harness.id

        let model: SessionModel
        if let resumeAgentSessionId {
            // Resume an existing agent session and replay its history.
            let response = try await client.loadSession(LoadSessionRequest(
                sessionId: resumeAgentSessionId,
                cwd: workspace.folderURL.path,
                mcpServers: []
            ))
            connectedAgentSessionId = resumeAgentSessionId
            model = SessionModel(
                client: client,
                sessionId: resumeAgentSessionId,
                modeState: response.modes,
                configOptions: response.configOptions ?? []
            )
            await model.loadHistory()
        } else {
            // Create a brand-new agent session.
            let session = try await client.newSession(NewSessionRequest(
                cwd: workspace.folderURL.path,
                mcpServers: []
            ))
            connectedAgentSessionId = session.sessionId
            onAgentSessionCreated?(session.sessionId)
            model = SessionModel(
                client: client,
                sessionId: session.sessionId,
                modeState: session.modes,
                configOptions: session.configOptions ?? []
            )
        }

        if let pendingModeId {
            await model.setMode(pendingModeId)
        }
        pendingModeId = nil

        // Apply any config the user picked before connecting.
        for (configId, value) in pendingConfig {
            await model.setConfigOption(configId: configId, value: value)
        }
        pendingConfig.removeAll()

        // Refresh the cache with the live options (stale-while-revalidate).
        configCache.store(model.configOptions, forHarness: harness.id)
        return model
    }

    private func connectServerSession(
        _ harness: DiscoveredAgent,
        serverClient: any HerdManServerClienting,
        session: inout ChatSession
    ) async throws -> SessionModel {
        if session.harnessId.isEmpty {
            session.harnessId = harness.id
        }
        if session.agentSessionId == nil, let resumeAgentSessionId {
            session.agentSessionId = resumeAgentSessionId
        }

        _ = try await serverClient.upsertWorkspace(workspace)
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

    private func prepareFromServerCapabilities(_ serverClient: any HerdManServerClienting) async -> Bool {
        do {
            let response = try await serverClient.capabilities(cwd: workspace.folderURL.path)
            let isNewChat = resumeAgentSessionId == nil
            let capabilities = response.harnesses.filter { capability in
                capability.harness.enabled && capability.harness.readiness.state == "ready"
            }
            let agents = capabilities.map(\.harness.discoveredAgent)
            if let settings, isNewChat {
                let enabled = agents.filter { settings.isHarnessEnabled($0.id) }
                harnesses = enabled.isEmpty ? agents : enabled
            } else {
                harnesses = agents
            }
            for capability in capabilities {
                configCache.store(capability.configOptions, forHarness: capability.harness.id)
                configOptionsByHarness[capability.harness.id] = capability.configOptions
                if let modes = capability.modes {
                    modeStateByHarness[capability.harness.id] = modes
                }
            }
            configCache.store(capabilities, forServer: workspace.serverId)
            if isNewChat {
                if selectedHarnessId == nil || !harnesses.contains(where: { $0.id == selectedHarnessId }) {
                    selectedHarnessId = harnesses.first?.id
                }
            } else if selectedHarnessId == nil {
                selectedHarnessId = harnesses.first?.id
            }
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    private func seedFromCachedServerCapabilities() -> Bool {
        guard serverClient != nil else { return false }
        let cached = configCache.capabilities(forServer: workspace.serverId).filter { capability in
            capability.harness.enabled && capability.harness.readiness.state == "ready"
        }
        guard !cached.isEmpty else { return false }
        let agents = cached.map(\.harness.discoveredAgent)
        let isNewChat = resumeAgentSessionId == nil
        if let settings, isNewChat {
            let enabled = agents.filter { settings.isHarnessEnabled($0.id) }
            harnesses = enabled.isEmpty ? agents : enabled
        } else {
            harnesses = agents
        }
        for capability in cached {
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
        return true
    }
}

#if DEBUG
extension SessionController {
    /// A controller pre-populated for previews.
    static func preview(
        workspace: Workspace = Workspace(name: "shepherd", folderURL: URL(fileURLWithPath: "/tmp/shepherd")),
        model: SessionModel? = nil,
        harnesses: [DiscoveredAgent] = SessionController.previewHarnesses
    ) -> SessionController {
        let controller = SessionController(
            workspace: workspace,
            agentService: PreviewAgentService(),
            configCache: ConfigOptionCache(store: InMemoryStore())
        )
        controller.harnesses = harnesses
        controller.selectedHarnessId = harnesses.first?.id
        controller.model = model
        return controller
    }

    nonisolated static var previewHarnesses: [DiscoveredAgent] {
        [
            DiscoveredAgent(id: "claude-code", name: "Claude Code", source: .registry, method: .npx, readiness: .ready, symbolName: "sparkle"),
            DiscoveredAgent(id: "codex", name: "Codex", source: .registry, method: .npx, readiness: .ready, symbolName: "chevron.left.forwardslash.chevron.right")
        ]
    }
}
#endif
