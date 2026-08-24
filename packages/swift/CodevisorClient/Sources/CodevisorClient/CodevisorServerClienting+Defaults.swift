import ACPKit
import CodevisorProtocol
import Foundation

public extension CodevisorServerClienting {
    func listProjectGitBranches(projectId: UUID) async throws -> [ServerProjectGitBranch] { [] }

    func updateProjectWorktreeBase(
        id: UUID,
        worktreeBase: ProjectWorktreeBase?
    ) async throws -> ServerProject {
        throw CodevisorServerClientError.invalidResponse
    }

    /// Defaults for fakes and relay transports that don't manage a machine's
    /// cloud registration: report "not registered" and refuse to change it.
    func cloudRegistration() async throws -> ServerCloudRegistration {
        ServerCloudRegistration(connected: false)
    }

    func connectCloud(serverURL _: URL, sessionToken _: String) async throws -> String {
        throw CodevisorServerClientError.invalidResponse
    }

    func disconnectCloud() async throws {}

    /// Cached-read stable-channel default so existing call sites keep
    /// compiling; pass `refresh: true` (and the user's channel) when the
    /// result is shown to the user right away.
    func updateInfo() async throws -> ServerUpdateInfo {
        try await updateInfo(refresh: false, channel: .stable)
    }

    /// Stable-channel default for callers without a channel preference.
    func applyServerUpdate() async throws -> ServerUpdateApplied {
        try await applyServerUpdate(channel: .stable)
    }

    /// Defaults for fakes/older servers without the config plane: an empty
    /// replica, and a merge that simply echoes what was pushed.
    func syncDocument(namespace: String) async throws -> ServerSyncDocument {
        ServerSyncDocument(namespace: namespace, entries: [])
    }
    func mergeSyncDocument(
        namespace: String,
        entries: [ServerSyncEntry]
    ) async throws -> ServerSyncDocument {
        ServerSyncDocument(namespace: namespace, entries: entries)
    }

    /// Compatibility fallback for test doubles and pre-tailnet servers: no
    /// discovery. The HTTP client overrides this with the real request.
    func tailnetPeers() async throws -> ServerTailnetPeers {
        ServerTailnetPeers(available: false, peers: [])
    }

    /// Compatibility fallback for test doubles and older transports. The HTTP
    /// client overrides this with the server-side filtered request.
    func capabilities(cwd: String, harnessId: String) async throws -> ServerCapabilities {
        let response = try await capabilities(cwd: cwd)
        return ServerCapabilities(
            harnesses: response.harnesses.filter { $0.harness.id == harnessId }
        )
    }

    func capabilities(
        cwd: String,
        harnessId: String,
        configSelections _: [String: String]
    ) async throws -> ServerCapabilities {
        try await capabilities(cwd: cwd, harnessId: harnessId)
    }

    func setSessionConfigAndReturnOptions(
        id: UUID,
        configId: String,
        value: String
    ) async throws -> [SessionConfigOption]? {
        try await setSessionConfig(id: id, configId: configId, value: value)
        return nil
    }

    func openBrowserExtensionFolder() async throws -> ServerBrowserUseConfiguration {
        throw CodevisorServerClientError.invalidResponse
    }

    func openBrowserExtensionsPage() async throws -> ServerBrowserUseConfiguration {
        throw CodevisorServerClientError.invalidResponse
    }

    func openBrowserExtensionWebStore() async throws -> ServerBrowserUseConfiguration {
        throw CodevisorServerClientError.invalidResponse
    }

    func browserExtensionArchive() async throws -> URL {
        throw CodevisorServerClientError.invalidResponse
    }

    func browserExtensionIcon() async throws -> URL {
        throw CodevisorServerClientError.invalidResponse
    }

    func connectSession(id: UUID) async throws -> ServerSessionRuntimeMetadata? { nil }

    /// Default for fakes/older transports: no combined open — callers use
    /// the discrete calls. The HTTP client overrides with the real endpoint.
    func openSession(
        _ session: ChatSession,
        project: Project?,
        transcriptLimit: Int
    ) async throws -> ServerSessionOpenResponse? { nil }

    /// Workspace-aware form used by native session controllers. Older/fake
    /// transports fall back to the pre-workspace request.
    func openSession(
        _ session: ChatSession,
        project: Project?,
        workspaceId: UUID?,
        transcriptLimit: Int
    ) async throws -> ServerSessionOpenResponse? {
        try await openSession(session, project: project, transcriptLimit: transcriptLimit)
    }

    /// Workspace-aware session upsert. Compatibility transports safely drop
    /// the association; current HTTP servers persist it.
    func upsertSession(_ session: ChatSession, workspaceId: UUID?) async throws -> ServerSession {
        try await upsertSession(session)
    }

    /// Compatibility fallback for test doubles and servers without the
    /// plugins feature: no plugins, and no pane tokens. The HTTP client
    /// overrides both with the real requests.
    func listPlugins() async throws -> [ServerPluginSummary] { [] }

    func listPluginUpdates() async throws -> [ServerPluginUpdateStatus] { [] }

    func preparePluginUpdate(pluginId: String) async throws -> ServerPluginUpdatePlan {
        throw CodevisorServerClientError.invalidResponse
    }

    func applyPluginUpdate(pluginId: String, planId: String) async throws -> ServerPluginSummary {
        throw CodevisorServerClientError.invalidResponse
    }

    func pluginIcon(pluginId: String, paneType: String?) async throws -> ServerPluginIconAsset {
        throw CodevisorServerClientError.invalidResponse
    }

    func issuePluginPaneToken(
        pluginId: String,
        paneId: String,
        paneType: String,
        workspaceId: String?,
        cwd: String?,
        themeMode: String?
    ) async throws -> ServerPluginPaneTokenResponse {
        throw CodevisorServerClientError.invalidResponse
    }

    func fetchPluginRegistry(query: String?) async throws -> ServerPluginRegistryIndex {
        throw CodevisorServerClientError.invalidResponse
    }

    func discoverRemotePlugin(source: String) async throws -> ServerPluginRemoteDiscovery {
        throw CodevisorServerClientError.invalidResponse
    }

    func importRemotePlugin(source: String) async throws -> ServerPluginSummary {
        throw CodevisorServerClientError.invalidResponse
    }

    func linkPlugin(path: String) async throws -> ServerPluginSummary {
        throw CodevisorServerClientError.invalidResponse
    }

    func removePlugin(pluginId: String) async throws -> [ServerPluginSummary] {
        throw CodevisorServerClientError.invalidResponse
    }

    func restartPlugin(pluginId: String) async throws -> ServerPluginSummary {
        throw CodevisorServerClientError.invalidResponse
    }

    func restorePlugin(pluginId: String) async throws -> ServerPluginSummary {
        throw CodevisorServerClientError.invalidResponse
    }

    func setPluginEnabled(pluginId: String, enabled: Bool) async throws -> ServerPluginSummary {
        throw CodevisorServerClientError.invalidResponse
    }

    func listWorkspaces() async throws -> [ServerWorkspace]? { nil }
    func workspaceSnapshot() async throws -> ServerWorkspaceSnapshot? { nil }
    func upsertWorkspace(_ workspace: ServerWorkspace) async throws -> ServerWorkspace? { nil }
    func listWorkspacePanes() async throws -> [ServerWorkspacePane]? { nil }
    func upsertWorkspacePane(_ pane: ServerWorkspacePane) async throws -> ServerWorkspacePane? { nil }
    func promoteWorkspacePaneToChat(
        _ pane: ServerWorkspacePane,
        session: ChatSession
    ) async throws -> ServerWorkspacePanePromotion? { nil }
    func deleteWorkspacePane(workspaceId: UUID, paneId: UUID) async throws {}
    func closeWorkspacePane(workspaceId: UUID, paneId: UUID) async throws -> ServerWorkspacePane? {
        try await deleteWorkspacePane(workspaceId: workspaceId, paneId: paneId)
        return nil
    }

    func shellEventStream() -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
        // Test doubles and old transports preserve their existing behavior.
        eventStream(since: 0)
    }

    /// Default for fakes/older transports: filter the unfiltered stream in a
    /// detached task so unhandled kinds never reach the caller's actor. The
    /// HTTP client overrides this to also skip payload decoding.
    func shellEventStream(handledKinds: Set<String>) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
        let source = shellEventStream()
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in source where handledKinds.contains(event.kind) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func latestShellEventCursor() async throws -> Int { 0 }

    func shellEventStream(
        since: Int,
        handledKinds: Set<String>
    ) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
        let source = eventStream(since: since)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in source where handledKinds.contains(event.kind) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func sessionEventStream(id: UUID, since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
        let source = eventStream(since: since)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in source
                    where
                        event.subjectId.caseInsensitiveCompare(id.uuidString) == .orderedSame
                    {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func promptQueue(id: UUID) async throws -> [ServerPromptQueueItem] { [] }

    func markSessionRead(id: UUID, throughSequence: Int) async throws -> ServerSession? { nil }
    func markSessionUnread(id: UUID) async throws -> ServerSession? { nil }
    func clearSessionPlanApproval(id: UUID) async throws {}

    /// Default for fakes/older transports: a plain list (no PATH refresh).
    /// The HTTP client overrides this with the real rescan endpoint.
    func rescanHarnesses() async throws -> [ServerHarness] {
        try await listHarnesses()
    }

    /// Default for fakes/older servers: the plain list (no lifecycle fields).
    func listHarnessesWithLifecycle() async throws -> [ServerHarness] {
        try await listHarnesses()
    }

    /// Default for fakes/older transports: no native store to scan. The HTTP
    /// client overrides this with the real endpoint.
    func listAgentSessions(harnessId: String) async throws -> [SessionInfo] { [] }

    /// Defaults for fakes/older servers without custom-harness support.
    func listCustomHarnesses() async throws -> [ServerCustomHarnessSpec] { [] }
    func replaceCustomHarnesses(_ specs: [ServerCustomHarnessSpec]) async throws -> [ServerHarness] {
        throw CodevisorServerClientError.invalidResponse
    }
    func testCustomHarness(_ spec: ServerCustomHarnessSpec) async throws -> ServerCustomHarnessTestResult {
        throw CodevisorServerClientError.invalidResponse
    }

    /// Defaults for fakes/older servers without lifecycle support.
    func installHarness(id: String, methodId: String?) async throws -> ServerHarnessOperationStarted {
        throw CodevisorServerClientError.invalidResponse
    }
    func updateHarness(id: String) async throws -> ServerHarnessOperationStarted {
        throw CodevisorServerClientError.invalidResponse
    }
    func applyPendingHarnessUpdate(id: String) async throws {
        throw CodevisorServerClientError.invalidResponse
    }
    func cancelPendingHarnessUpdate(id: String) async throws {
        throw CodevisorServerClientError.invalidResponse
    }
    func bundledAppInfo(harnessId: String) async throws -> ServerHarnessBundledApp? { nil }
    func updateBundledApp(harnessId: String) async throws {
        throw CodevisorServerClientError.invalidResponse
    }
    func checkHarnessUpdates() async throws -> [ServerHarness] { try await listHarnesses() }

    func refreshHarnessAuth() async throws -> [ServerHarness] { try await listHarnesses() }
    func refreshHarnessAuth(harnessId: String) async throws -> ServerHarness {
        guard let harness = try await refreshHarnessAuth().first(where: { $0.id == harnessId }) else {
            throw CodevisorServerClientError.invalidResponse
        }
        return harness
    }
    func listHarnessAccounts(harnessId: String) async throws -> [ServerHarnessAccount] { [] }
    func createHarnessAccount(harnessId: String, label: String?) async throws -> ServerHarnessAccount {
        throw CodevisorServerClientError.invalidResponse
    }
    func renameHarnessAccount(harnessId: String, accountId: String, label: String) async throws -> ServerHarnessAccount
    {
        throw CodevisorServerClientError.invalidResponse
    }
    func removeHarnessAccount(harnessId: String, accountId: String) async throws {}
    func activateHarnessAccount(harnessId: String, accountId: String) async throws -> [ServerHarnessAccount] { [] }
    func probeHarnessAccount(harnessId: String, accountId: String) async throws -> ServerHarnessAccount {
        throw CodevisorServerClientError.invalidResponse
    }
    func loginHarnessAccount(
        harnessId: String, accountId: String, methodId: String?, apiKey: String?
    ) async throws -> ServerHarnessAuthFlow {
        throw CodevisorServerClientError.invalidResponse
    }
    func cancelHarnessLogin(harnessId: String, accountId: String, flowId: String) async throws {}
    func logoutHarnessAccount(harnessId: String, accountId: String) async throws -> ServerHarnessAccount {
        throw CodevisorServerClientError.invalidResponse
    }
    func listPiAuthProviders() async throws -> [ServerPiAuthProvider] { [] }
    func startPiAuth(providerId: String, method: String) async throws -> ServerPiAuthFlow {
        throw CodevisorServerClientError.invalidResponse
    }
    func piAuthFlow(id: String) async throws -> ServerPiAuthFlow {
        throw CodevisorServerClientError.invalidResponse
    }
    func answerPiAuthFlow(id: String, value: String) async throws -> ServerPiAuthFlow {
        throw CodevisorServerClientError.invalidResponse
    }
    func cancelPiAuthFlow(id: String) async throws {}
    func removePiAuthProvider(id: String) async throws {}
    func listOpenCodeAuthProviders(accountId: String) async throws -> [ServerOpenCodeAuthProvider] { [] }
    func startOpenCodeAuth(
        accountId: String, providerId: String, methodId: String, inputs: [String: String]?, apiKey: String?
    ) async throws -> ServerOpenCodeAuthFlow {
        throw CodevisorServerClientError.invalidResponse
    }
    func openCodeAuthFlow(id: String) async throws -> ServerOpenCodeAuthFlow {
        throw CodevisorServerClientError.invalidResponse
    }
    func answerOpenCodeAuthFlow(id: String, code: String) async throws -> ServerOpenCodeAuthFlow {
        throw CodevisorServerClientError.invalidResponse
    }
    func cancelOpenCodeAuthFlow(id: String) async throws {}
    func removeOpenCodeAuthProvider(accountId: String, providerId: String) async throws {}
    func listMcpServers() async throws -> [ServerMcpServer] { [] }
    func browserUseConfiguration() async throws -> ServerBrowserUseConfiguration {
        .init(chromeAvailable: false, chromeConnected: false, managedAvailable: true)
    }
    func setPreferredBrowser(_ preference: String) async throws -> ServerBrowserUseConfiguration {
        throw CodevisorServerClientError.invalidResponse
    }
    func installDevelopmentBrowserExtension() async throws -> ServerBrowserUseConfiguration {
        throw CodevisorServerClientError.invalidResponse
    }
    func detectMcpAuth(url: String) async throws -> ServerMcpAuthDetection {
        .init(authType: "none", detail: "No authorization challenge detected")
    }
    func createMcpServer(_ request: CreateMcpServerBody) async throws -> ServerMcpServer {
        throw CodevisorServerClientError.invalidResponse
    }
    func updateMcpServer(id: String, request: UpdateMcpServerBody) async throws -> ServerMcpServer {
        throw CodevisorServerClientError.invalidResponse
    }
    func setMcpServerEnabled(id: String, enabled: Bool) async throws -> ServerMcpServer {
        throw CodevisorServerClientError.invalidResponse
    }
    func connectMcpServer(id: String) async throws -> ServerMcpServer {
        throw CodevisorServerClientError.invalidResponse
    }
    func startMcpOAuth(id: String) async throws -> ServerMcpOAuthStart {
        throw CodevisorServerClientError.invalidResponse
    }
    func disconnectMcpOAuth(id: String) async throws -> ServerMcpServer {
        throw CodevisorServerClientError.invalidResponse
    }
    func removeMcpServer(id: String) async throws {}
    func listMcpTools(id: String) async throws -> [ServerMcpTool] { [] }
    /// Defaults for fakes/older servers: empty scans hide the sections and
    /// mutations report the endpoint as unavailable.
    func listNativeMcps() async throws -> ServerNativeMcpScan {
        ServerNativeMcpScan(candidates: [], harnesses: [])
    }
    func listSkills() async throws -> ServerSkillsScan {
        ServerSkillsScan(canonicalDir: "", global: [], harnesses: [])
    }
    func importNativeMcps(identities: [String]) async throws -> ServerNativeMcpImportResult {
        throw CodevisorServerClientError.invalidResponse
    }
    func removeNativeMcp(harnessId: String, serverName: String) async throws -> ServerRemoveNativeMcpResult {
        throw CodevisorServerClientError.invalidResponse
    }
    func listNativeMcpRemovals() async throws -> [ServerNativeMcpRemoval] { [] }
    func restoreNativeMcpRemoval(id: String) async throws -> ServerNativeMcpScan {
        throw CodevisorServerClientError.invalidResponse
    }
    func setNativeMcpEnabled(harnessId: String, serverName: String, enabled: Bool) async throws -> ServerNativeMcpScan {
        throw CodevisorServerClientError.invalidResponse
    }
    func createSkill(name: String, description: String, content: String?) async throws -> ServerSkillsScan {
        throw CodevisorServerClientError.invalidResponse
    }
    func importSkill(path: String) async throws -> ServerSkillsScan {
        throw CodevisorServerClientError.invalidResponse
    }
    func discoverRemoteSkills(source: String) async throws -> [ServerRemoteSkillCandidate] {
        throw CodevisorServerClientError.invalidResponse
    }
    func importRemoteSkill(source: String, skillNames: [String]?) async throws -> ServerSkillsScan {
        throw CodevisorServerClientError.invalidResponse
    }
    func removeSkill(directoryName: String) async throws -> ServerSkillsScan {
        throw CodevisorServerClientError.invalidResponse
    }
    func setSkillInstalled(directoryName: String, harnessId: String, installed: Bool) async throws -> ServerSkillsScan {
        throw CodevisorServerClientError.invalidResponse
    }
    func makeSkillGlobal(harnessId: String, directoryName: String) async throws -> ServerSkillsScan {
        throw CodevisorServerClientError.invalidResponse
    }
    func syncSkills(directoryNames: [String]?) async throws -> ServerSkillsScan {
        throw CodevisorServerClientError.invalidResponse
    }

    /// Default for fakes/older transports: attachments are dropped and the
    /// text-only prompt path is used.
    func promptSession(id: UUID, text: String, attachments: [ServerAttachmentRef]) async throws -> ServerPromptAccepted
    {
        try await promptSession(id: id, text: text)
    }

    /// Default for fakes/older transports: the message id is advisory (it
    /// only sharpens echo reconciliation), so dropping it is safe.
    func promptSession(
        id: UUID, text: String, attachments: [ServerAttachmentRef], messageId: String?
    ) async throws -> ServerPromptAccepted {
        try await promptSession(id: id, text: text, attachments: attachments)
    }

    /// Defaults so fakes and older transports keep compiling; the HTTP client
    /// overrides these with the real file endpoints.
    func uploadFile(name: String, mimeType: String, data: Data) async throws -> ServerFileMetadata {
        throw CodevisorServerClientError.invalidResponse
    }

    func fileData(id: String) async throws -> Data {
        throw CodevisorServerClientError.invalidResponse
    }

    func fileData(sessionId: UUID, path: String) async throws -> Data {
        throw CodevisorServerClientError.invalidResponse
    }

    func fileVersion(sessionId: UUID, path: String) async throws -> String? {
        nil
    }

    /// Default for fakes/older servers: no persisted history, callers fall
    /// back to the text-only conversation snapshot.
    func sessionEvents(id: UUID) async throws -> [ServerEventEnvelope] { [] }

    func transcriptPage(id: UUID, before: String?, limit: Int) async throws -> ServerTranscriptPage {
        throw CodevisorServerClientError.httpStatus(404, "")
    }

    func sessionUsageLimits(id: UUID) async throws -> ServerHarnessUsageLimits {
        throw CodevisorServerClientError.httpStatus(404, "")
    }

    func transcriptItemDetails(id: UUID, itemId: String) async throws -> ServerTranscriptItemDetails {
        throw CodevisorServerClientError.httpStatus(404, "")
    }

    /// Defaults so fakes and older transports keep compiling; the HTTP client
    /// overrides these with the real goal endpoints.
    @discardableResult
    func setSessionGoal(
        id: UUID,
        objective: String?,
        status: GoalStatus?,
        tokenBudget: TokenBudgetUpdate
    ) async throws -> SessionGoal {
        throw CodevisorServerClientError.invalidResponse
    }

    func clearSessionGoal(id: UUID) async throws {}

    func answerSessionQuestion(
        id: UUID,
        questionId: String,
        outcome: String,
        answers: [String: QuestionAnswerEntry]?
    ) async throws {}

    /// Default no-op so fakes and older transports keep compiling; the HTTP
    /// client overrides this with `POST /v1/shutdown`.
    func requestShutdown() async throws {}

    /// Default for fakes/older transports: the server declined the update.
    func applyServerUpdate(channel _: ServerUpdateChannel) async throws -> ServerUpdateApplied {
        ServerUpdateApplied(accepted: false, targetVersion: nil)
    }

    func updateQueuedPrompt(sessionId: UUID, queueItemId: String, text: String) async throws -> ServerPromptQueueItem {
        ServerPromptQueueItem(
            id: queueItemId,
            sessionId: sessionId.uuidString,
            text: text,
            createdAt: ServerDateCoding.string(from: Date()),
            updatedAt: ServerDateCoding.string(from: Date())
        )
    }

    func reorderQueuedPrompts(
        sessionId: UUID,
        queueItemIds _: [String]
    ) async throws -> [ServerPromptQueueItem] {
        try await promptQueue(id: sessionId)
    }

    func deleteQueuedPrompt(sessionId: UUID, queueItemId: String) async throws {}

    /// Defaults so fakes and older transports keep compiling; the HTTP client
    /// overrides these with the real worktree endpoints.
    func listWorktrees(projectId: UUID) async throws -> [ServerWorktree] { [] }

    /// Notes sync is best-effort; fakes/older servers act notes-less.

    /// Workspace archive sync is best-effort for the same reason: a fake or a
    /// server predating the route leaves the local flag authoritative.
    func setWorkspaceArchived(id: UUID, isArchived: Bool) async throws {}

    func createWorktree(projectId: UUID, name: String?) async throws -> ServerWorktree {
        throw CodevisorServerClientError.invalidResponse
    }

    /// Default for fakes/older transports: the id is dropped and the plain
    /// create path is used (no setup-progress correlation).
    func createWorktree(projectId: UUID, id: String?, name: String?) async throws -> ServerWorktree {
        try await createWorktree(projectId: projectId, name: name)
    }

    /// Default for fakes/older servers: fall back to issuing a fresh pairing
    /// token when the stable connection-token endpoint isn't available.
    func connectionToken() async throws -> ServerPairingToken {
        try await issuePairingToken()
    }

    /// Defaults so fakes and older transports keep compiling; the HTTP client
    /// overrides these with the real filesystem and clone endpoints.
    func listDirectory(path: String?, showHidden: Bool) async throws -> ServerFsListing {
        throw CodevisorServerClientError.invalidResponse
    }

    func createProjectFromGit(id: UUID, url: String, name: String?) async throws -> ServerProject {
        throw CodevisorServerClientError.invalidResponse
    }

    /// Defaults so fakes and older transports keep compiling; the HTTP client
    /// overrides these with the real scratch-workspace endpoints.
    func createScratchProject(id: UUID) async throws -> ServerProject {
        throw CodevisorServerClientError.invalidResponse
    }

    func moveSession(id: UUID, projectId: UUID, worktreeName: String?) async throws -> ServerSession {
        throw CodevisorServerClientError.invalidResponse
    }
}
