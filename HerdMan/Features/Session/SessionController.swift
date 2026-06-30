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
    /// Called with the agent session id once a brand-new session is created.
    var onAgentSessionCreated: ((String) -> Void)?
    /// The agent session id currently connected (resumed or newly created).
    private(set) var connectedAgentSessionId: String?

    private let agentService: any AgentServicing
    private let configCache: ConfigOptionCache
    private let settings: AppSettingsModel?
    private var delegate: AppClientDelegate?
    private var client: ACPClient?
    private var hasSentFirst = false
    private var connectedHarnessId: String?
    /// Config changes made before connecting, applied once the agent connects.
    private var pendingConfig: [String: String] = [:]

    init(
        workspace: Workspace,
        agentService: any AgentServicing,
        configCache: ConfigOptionCache,
        settings: AppSettingsModel? = nil
    ) {
        self.workspace = workspace
        self.agentService = agentService
        self.configCache = configCache
        self.settings = settings
    }

    var isPrepared: Bool { !harnesses.isEmpty }

    // MARK: - Derived state

    var conversation: [ConversationItem] { model?.conversation ?? [] }
    var isConnected: Bool { model != nil }
    var modeState: SessionModeState? { model?.modeState }
    var errorMessage: String? { model?.errorMessage }

    /// Selectable config options: live when connected, otherwise the cached
    /// (stale) options for the selected harness with any pending edits applied.
    var configOptions: [SessionConfigOption] {
        if let model { return model.configOptions }
        guard let harnessId = selectedHarnessId else { return [] }
        return configCache.options(forHarness: harnessId).map { option in
            guard let pending = pendingConfig[option.id] else { return option }
            var updated = option
            updated.currentValue = pending
            return updated
        }
    }

    /// The config options shown as composer pickers, in a sensible order.
    var pickerOptions: [SessionConfigOption] {
        let order = [SessionConfigOption.Category.model, SessionConfigOption.Category.thoughtLevel]
        return configOptions
            .filter { !$0.options.isEmpty && order.contains($0.category ?? "") }
            .sorted { order.firstIndex(of: $0.category ?? "") ?? 99 < order.firstIndex(of: $1.category ?? "") ?? 99 }
    }

    func setConfigOption(_ configId: String, _ value: String) async {
        if let model {
            await model.setConfigOption(configId: configId, value: value)
            if let harnessId = connectedHarnessId {
                configCache.store(model.configOptions, forHarness: harnessId)
            }
        } else {
            // Not connected yet: remember it and apply on connect.
            pendingConfig[configId] = value
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
            && !isBusy
            && (isConnected || selectedHarness != nil)
    }

    // MARK: - Actions

    /// Discovers installed harnesses for the picker. For a new chat the list
    /// honors the user's enabled set (falling back to all installed if they've
    /// disabled everything); a resumed session always keeps its own harness.
    func prepare() async {
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
        await reconnect()
    }

    /// Changes the project/workspace (user action) and reconnects.
    func selectWorkspace(_ workspace: Workspace) async {
        guard workspace.id != self.workspace.id else { return }
        self.workspace = workspace
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
        guard !text.isEmpty, !isBusy else { return }

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

    func setMode(_ modeId: String) async {
        await model?.setMode(modeId)
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
                fs: FileSystemCapabilities(readTextFile: true, writeTextFile: true)
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

        // Apply any config the user picked before connecting.
        for (configId, value) in pendingConfig {
            await model.setConfigOption(configId: configId, value: value)
        }
        pendingConfig.removeAll()

        // Refresh the cache with the live options (stale-while-revalidate).
        configCache.store(model.configOptions, forHarness: harness.id)
        return model
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
