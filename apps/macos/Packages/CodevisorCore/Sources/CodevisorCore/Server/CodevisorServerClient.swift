import Foundation
import ACPKit

public enum CodevisorServerClientError: Error, Equatable, Sendable, LocalizedError {
    case invalidURL(String)
    case invalidResponse
    case httpStatus(Int, String)
    case invalidDate(String)
    case invalidUUID(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidURL(url):
            "The server address “\(url)” isn't valid."
        case .invalidResponse:
            "The Codevisor server sent an unexpected response. Try again in a moment."
        case let .httpStatus(_, body):
            body.isEmpty ? "The Codevisor server rejected the request." : body
        case .invalidDate, .invalidUUID:
            "The Codevisor server sent data this version of Codevisor couldn't read. Updating Codevisor may fix this."
        }
    }
}

/// The machine-readable failure category from a server error body
/// (`{"error": …, "code": …}`), when the server classified the failure —
/// clone errors use this to pick actionable guidance.
public func serverErrorCode(_ error: any Error) -> String? {
    guard case let CodevisorServerClientError.httpStatus(_, body) = error,
          let data = body.data(using: .utf8),
          let payload = try? JSONDecoder().decode([String: String?].self, from: data)
    else { return nil }
    return payload["code"] ?? nil
}

/// The one message used for connection-level failures. Views compare an
/// error string against this to pair the message with a "Restart" recovery
/// action (HIG: offer the way out right where the error appears).
public let serverUnreachableErrorMessage = "Can't connect to the Codevisor server."

/// True when an error only says "the surrounding task was cancelled" —
/// Swift task cancellation or the URLSession request it tore down. These are
/// lifecycle noise (a pane was re-hosted, a view disappeared mid-load), not
/// failures: callers should return silently instead of surfacing them, since
/// whatever remounts the view reloads from scratch anyway. Without this
/// filter, every workspace-layout churn painted "cancelled" error rows into
/// otherwise healthy chats.
public func isTaskCancellation(_ error: any Error) -> Bool {
    if error is CancellationError { return true }
    if let urlError = error as? URLError, urlError.code == .cancelled { return true }
    return false
}

/// A human-readable message for errors surfaced in the UI (HIG: say what
/// happened and what to do next, in plain language — never a raw NSError
/// dump). HTTP failures carry a JSON `{"error": "..."}` body from the
/// server — show that sentence, not the wrapped enum description.
public func serverErrorMessage(_ error: any Error) -> String {
    if case let CodevisorServerClientError.httpStatus(_, body) = error {
        if let data = body.data(using: .utf8),
           let payload = try? JSONDecoder().decode([String: String].self, from: data),
           let message = payload["error"] {
            return message
        }
        return body.isEmpty ? "The Codevisor server rejected the request." : body
    }
    // Connection-level failures: the URL, task ids, and CFNetwork internals
    // mean nothing to the user — reduce to the situation and the way out.
    if let urlError = error as? URLError {
        switch urlError.code {
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
             .timedOut, .secureConnectionFailed, .cannotLoadFromNetwork:
            return serverUnreachableErrorMessage
        case .notConnectedToInternet, .internationalRoamingOff, .dataNotAllowed:
            return "You appear to be offline. Check your network connection, then try again."
        default:
            return urlError.localizedDescription
        }
    }
    if let localized = error as? LocalizedError, let description = localized.errorDescription {
        return description
    }
    // Cocoa/POSIX errors carry a system-provided sentence; anything else
    // falls back to its description rather than showing nothing.
    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain || nsError.domain == NSURLErrorDomain
        || nsError.domain == NSPOSIXErrorDomain {
        return nsError.localizedDescription
    }
    return String(describing: error)
}

public protocol CodevisorServerClienting: Sendable {
    func health() async throws -> ServerHealth
    func info() async throws -> ServerInfo
    /// `refresh` bypasses the server's update-check cache (older servers
    /// ignore the flag).
    func updateInfo(refresh: Bool) async throws -> ServerUpdateInfo
    func issuePairingToken() async throws -> ServerPairingToken
    /// The machine's stable connection token (unchanged across restarts and
    /// updates until rotated). Preferred over `issuePairingToken` for showing
    /// a token to copy, so it stays consistent.
    func connectionToken() async throws -> ServerPairingToken
    func capabilities(cwd: String) async throws -> ServerCapabilities
    /// Inspects only one known harness. Existing chats use this overload so
    /// unrelated agents never enter their loading path.
    func capabilities(cwd: String, harnessId: String) async throws -> ServerCapabilities
    func listHarnesses() async throws -> [ServerHarness]
    /// The list with lifecycle decoration (update knowledge, install
    /// methods) — for Settings and update banners. The plain `listHarnesses`
    /// stays as light as possible for the composer's picker.
    func listHarnessesWithLifecycle() async throws -> [ServerHarness]
    /// Asks the server to re-resolve its PATH (login-shell probe) before
    /// re-detecting, so CLIs installed after server start are found.
    func rescanHarnesses() async throws -> [ServerHarness]
    /// Sessions from the harness's own on-disk store (run before/outside
    /// Codevisor) — the source for onboarding's workspace suggestions and
    /// "import existing chats".
    func listAgentSessions(harnessId: String) async throws -> [SessionInfo]
    func setHarnessEnabled(id: String, enabled: Bool) async throws -> ServerHarness
    /// User-defined custom ACP harnesses (BYO): persisted server-side in a
    /// user-editable file and merged into the harness catalog.
    func listCustomHarnesses() async throws -> [ServerCustomHarnessSpec]
    /// Whole-list replace; returns the refreshed full harness list.
    func replaceCustomHarnesses(_ specs: [ServerCustomHarnessSpec]) async throws -> [ServerHarness]
    /// One-shot ACP initialize handshake for a (possibly unsaved) spec.
    func testCustomHarness(_ spec: ServerCustomHarnessSpec) async throws -> ServerCustomHarnessTestResult
    /// Starts a one-click install (202-ack; progress arrives via
    /// harness.lifecycle.updated events). Returns the output terminal id.
    func installHarness(id: String, methodId: String?) async throws -> ServerHarnessOperationStarted
    /// Starts a one-click update via the harness's origin-matched flow.
    /// Returns `queued: true` when chats are mid-turn — the update runs when
    /// they finish.
    func updateHarness(id: String) async throws -> ServerHarnessOperationStarted
    /// Dual-install: the bundled desktop app's version/update state (nil
    /// when the harness has no bundled app). Computed server-side on demand.
    func bundledAppInfo(harnessId: String) async throws -> ServerHarnessBundledApp?
    /// Runs the verified bundle swap for the bundled desktop app.
    func updateBundledApp(harnessId: String) async throws
    /// "Update Now" on a queued update — skips the idle wait.
    func applyPendingHarnessUpdate(id: String) async throws
    /// Disarms a queued update entirely.
    func cancelPendingHarnessUpdate(id: String) async throws
    /// Forces a latest-version check for all harnesses, returning the
    /// refreshed decorated list.
    func checkHarnessUpdates() async throws -> [ServerHarness]
    func refreshHarnessAuth() async throws -> [ServerHarness]
    func refreshHarnessAuth(harnessId: String) async throws -> ServerHarness
    func listHarnessAccounts(harnessId: String) async throws -> [ServerHarnessAccount]
    func createHarnessAccount(harnessId: String, label: String?) async throws -> ServerHarnessAccount
    func renameHarnessAccount(harnessId: String, accountId: String, label: String) async throws -> ServerHarnessAccount
    func removeHarnessAccount(harnessId: String, accountId: String) async throws
    func activateHarnessAccount(harnessId: String, accountId: String) async throws -> [ServerHarnessAccount]
    func probeHarnessAccount(harnessId: String, accountId: String) async throws -> ServerHarnessAccount
    func loginHarnessAccount(harnessId: String, accountId: String, methodId: String?, apiKey: String?) async throws -> ServerHarnessAuthFlow
    func cancelHarnessLogin(harnessId: String, accountId: String, flowId: String) async throws
    func logoutHarnessAccount(harnessId: String, accountId: String) async throws -> ServerHarnessAccount
    func listPiAuthProviders() async throws -> [ServerPiAuthProvider]
    func startPiAuth(providerId: String, method: String) async throws -> ServerPiAuthFlow
    func piAuthFlow(id: String) async throws -> ServerPiAuthFlow
    func answerPiAuthFlow(id: String, value: String) async throws -> ServerPiAuthFlow
    func cancelPiAuthFlow(id: String) async throws
    func removePiAuthProvider(id: String) async throws
    func listOpenCodeAuthProviders(accountId: String) async throws -> [ServerOpenCodeAuthProvider]
    func startOpenCodeAuth(accountId: String, providerId: String, methodId: String, inputs: [String: String]?, apiKey: String?) async throws -> ServerOpenCodeAuthFlow
    func openCodeAuthFlow(id: String) async throws -> ServerOpenCodeAuthFlow
    func answerOpenCodeAuthFlow(id: String, code: String) async throws -> ServerOpenCodeAuthFlow
    func cancelOpenCodeAuthFlow(id: String) async throws
    func removeOpenCodeAuthProvider(accountId: String, providerId: String) async throws
    func listMcpServers() async throws -> [ServerMcpServer]
    func browserUseConfiguration() async throws -> ServerBrowserUseConfiguration
    func setPreferredBrowser(_ preference: String) async throws -> ServerBrowserUseConfiguration
    func installDevelopmentBrowserExtension() async throws -> ServerBrowserUseConfiguration
    func openBrowserExtensionFolder() async throws -> ServerBrowserUseConfiguration
    func openBrowserExtensionsPage() async throws -> ServerBrowserUseConfiguration
    func openBrowserExtensionWebStore() async throws -> ServerBrowserUseConfiguration
    func browserExtensionArchive() async throws -> URL
    func browserExtensionIcon() async throws -> URL
    func detectMcpAuth(url: String) async throws -> ServerMcpAuthDetection
    func createMcpServer(_ request: CreateMcpServerBody) async throws -> ServerMcpServer
    func updateMcpServer(id: String, request: UpdateMcpServerBody) async throws -> ServerMcpServer
    func setMcpServerEnabled(id: String, enabled: Bool) async throws -> ServerMcpServer
    func connectMcpServer(id: String) async throws -> ServerMcpServer
    func startMcpOAuth(id: String) async throws -> ServerMcpOAuthStart
    func disconnectMcpOAuth(id: String) async throws -> ServerMcpServer
    func removeMcpServer(id: String) async throws
    func listMcpTools(id: String) async throws -> [ServerMcpTool]
    /// MCP servers registered directly in harness config files (read-only
    /// discovery; secret values never leave the server).
    func listNativeMcps() async throws -> ServerNativeMcpScan
    /// Import coalesced native candidates (by identity) into the managed
    /// gateway; secrets are re-read server-side.
    func importNativeMcps(identities: [String]) async throws -> ServerNativeMcpImportResult
    /// Remove a server from a harness's own config file (backed up and
    /// parked for undo).
    func removeNativeMcp(harnessId: String, serverName: String) async throws -> ServerRemoveNativeMcpResult
    func listNativeMcpRemovals() async throws -> [ServerNativeMcpRemoval]
    /// Undo a native removal by reinserting the parked entry.
    func restoreNativeMcpRemoval(id: String) async throws -> ServerNativeMcpScan
    /// Toggle a harness's own per-server enable flag (only where one exists).
    func setNativeMcpEnabled(harnessId: String, serverName: String, enabled: Bool) async throws -> ServerNativeMcpScan
    /// Skills in the canonical ~/.agents/skills store plus each harness's own
    /// skills directory.
    func listSkills() async throws -> ServerSkillsScan
    /// Create a skill in the canonical store — from a template, or from
    /// pasted SKILL.md content.
    func createSkill(name: String, description: String, content: String?) async throws -> ServerSkillsScan
    /// Import a local skill folder (a path on the server's machine) into the
    /// canonical store.
    func importSkill(path: String) async throws -> ServerSkillsScan
    /// List the skills a remote source offers (GitHub/GitLab repos, git
    /// URLs, or sites publishing skills via well-known endpoints).
    func discoverRemoteSkills(source: String) async throws -> [ServerRemoteSkillCandidate]
    /// Import skills from a remote source into the canonical store,
    /// optionally narrowed to a selection from discovery.
    func importRemoteSkill(source: String, skillNames: [String]?) async throws -> ServerSkillsScan
    /// Delete a canonical skill and sweep its links from every harness.
    func removeSkill(directoryName: String) async throws -> ServerSkillsScan
    /// Install (symlink) or uninstall a canonical skill for one harness.
    func setSkillInstalled(directoryName: String, harnessId: String, installed: Bool) async throws -> ServerSkillsScan
    /// Promote an independent harness-dir skill into the canonical store.
    func makeSkillGlobal(harnessId: String, directoryName: String) async throws -> ServerSkillsScan
    /// Link the named skills (or all of them) into every harness that needs
    /// a link, bringing harnesses in sync with the shared store.
    func syncSkills(directoryNames: [String]?) async throws -> ServerSkillsScan
    func listProjects() async throws -> [ServerProject]
    func upsertProject(_ project: Project) async throws -> ServerProject
    func updateProject(_ project: Project) async throws -> ServerProject
    func deleteProject(id: UUID) async throws
    func listWorktrees(projectId: UUID) async throws -> [ServerWorktree]
    /// A workspace's synced scratchpad notes; nil when none exist yet.
    func workspaceNotes(workspaceId: UUID) async throws -> ServerWorkspaceNotes?
    /// Uploads a workspace's notes (last-write-wins by `updatedAt`).
    func saveWorkspaceNotes(workspaceId: UUID, content: String, updatedAt: Date) async throws
    func createWorktree(projectId: UUID, name: String?) async throws -> ServerWorktree
    /// Creates a worktree with a client-supplied id so the caller can follow
    /// the server's `worktree.setup` progress events (subjectId = worktree id)
    /// while the request is still in flight.
    func createWorktree(projectId: UUID, id: String?, name: String?) async throws -> ServerWorktree
    /// Directory listing for the remote project picker (directories only).
    /// Nil path lists the server's home directory.
    func listDirectory(path: String?, showHidden: Bool) async throws -> ServerFsListing
    /// Clones a git remote into the machine's managed repos directory and
    /// registers the checkout as a project. The client-supplied id lets the
    /// caller follow `project.setup` progress events while the clone runs.
    func createProjectFromGit(id: UUID, url: String, name: String?) async throws -> ServerProject
    func listSessions() async throws -> [ServerSession]
    func sessionDetail(id: UUID) async throws -> ServerSessionDetail
    func sessionUsageLimits(id: UUID) async throws -> ServerHarnessUsageLimits
    /// Starts or rebinds the existing agent runtime and returns its current,
    /// session-specific picker metadata. Nil means the server predates this
    /// endpoint and callers should keep the capability-cache fallback.
    func connectSession(id: UUID) async throws -> ServerSessionRuntimeMetadata?
    /// One-round-trip chat open: ensures the project and session records
    /// exist server-side (never overwriting an existing project) and returns
    /// the refreshed session together with its first transcript page. Nil
    /// means the server predates this endpoint and callers should fall back
    /// to the discrete listProjects/upsert/transcript calls.
    func openSession(
        _ session: ChatSession,
        project: Project?,
        transcriptLimit: Int
    ) async throws -> ServerSessionOpenResponse?
    func transcriptPage(id: UUID, before: String?, limit: Int) async throws -> ServerTranscriptPage
    func transcriptItemDetails(id: UUID, itemId: String) async throws -> ServerTranscriptItemDetails
    func promptQueue(id: UUID) async throws -> [ServerPromptQueueItem]
    func sessionEvents(id: UUID) async throws -> [ServerEventEnvelope]
    func upsertSession(_ session: ChatSession) async throws -> ServerSession
    func updateSession(_ session: ChatSession) async throws -> ServerSession
    func touchSession(id: UUID, updatedAt: Date) async throws
    func deleteSession(id: UUID) async throws
    func promptSession(id: UUID, text: String) async throws -> ServerPromptAccepted
    func promptSession(id: UUID, text: String, attachments: [ServerAttachmentRef]) async throws -> ServerPromptAccepted
    /// `messageId` is the CLIENT's id for its optimistic user message; the
    /// server adopts it as the queue item id, so the user echo comes back
    /// with the same id and reconciles by identity.
    func promptSession(id: UUID, text: String, attachments: [ServerAttachmentRef], messageId: String?) async throws -> ServerPromptAccepted
    func uploadFile(name: String, mimeType: String, data: Data) async throws -> ServerFileMetadata
    func fileData(id: String) async throws -> Data
    func updateQueuedPrompt(sessionId: UUID, queueItemId: String, text: String) async throws -> ServerPromptQueueItem
    func deleteQueuedPrompt(sessionId: UUID, queueItemId: String) async throws
    func cancelSession(id: UUID) async throws
    func setSessionMode(id: UUID, modeId: String) async throws
    func setSessionConfig(id: UUID, configId: String, value: String) async throws
    @discardableResult
    func setSessionGoal(
        id: UUID,
        objective: String?,
        status: GoalStatus?,
        tokenBudget: TokenBudgetUpdate
    ) async throws -> SessionGoal
    func clearSessionGoal(id: UUID) async throws
    func answerSessionQuestion(
        id: UUID,
        questionId: String,
        outcome: String,
        answers: [String: QuestionAnswerEntry]?
    ) async throws
    func requestShutdown() async throws
    func applyServerUpdate() async throws -> ServerUpdateApplied
    func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error>
    /// Project/session metadata changes after a freshly loaded shell snapshot.
    func shellEventStream() -> AsyncThrowingStream<ServerEventEnvelope, any Error>
    /// Session-scoped sequence and replay. Unlike the machine stream, `since`
    /// is meaningful only within this session.
    func sessionEventStream(id: UUID, since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error>
}

public extension CodevisorServerClienting {
    /// Cached-read default so existing call sites keep compiling; pass
    /// `refresh: true` when the result is shown to the user right away.
    func updateInfo() async throws -> ServerUpdateInfo {
        try await updateInfo(refresh: false)
    }

    /// Compatibility fallback for test doubles and older transports. The HTTP
    /// client overrides this with the server-side filtered request.
    func capabilities(cwd: String, harnessId: String) async throws -> ServerCapabilities {
        let response = try await capabilities(cwd: cwd)
        return ServerCapabilities(
            harnesses: response.harnesses.filter { $0.harness.id == harnessId }
        )
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

    func shellEventStream() -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
        // Test doubles and old transports preserve their existing behavior.
        eventStream(since: 0)
    }

    func sessionEventStream(id: UUID, since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
        let source = eventStream(since: since)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in source where
                        event.subjectId.caseInsensitiveCompare(id.uuidString) == .orderedSame {
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
    func renameHarnessAccount(harnessId: String, accountId: String, label: String) async throws -> ServerHarnessAccount {
        throw CodevisorServerClientError.invalidResponse
    }
    func removeHarnessAccount(harnessId: String, accountId: String) async throws {}
    func activateHarnessAccount(harnessId: String, accountId: String) async throws -> [ServerHarnessAccount] { [] }
    func probeHarnessAccount(harnessId: String, accountId: String) async throws -> ServerHarnessAccount {
        throw CodevisorServerClientError.invalidResponse
    }
    func loginHarnessAccount(harnessId: String, accountId: String, methodId: String?, apiKey: String?) async throws -> ServerHarnessAuthFlow {
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
    func startOpenCodeAuth(accountId: String, providerId: String, methodId: String, inputs: [String: String]?, apiKey: String?) async throws -> ServerOpenCodeAuthFlow {
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
    func promptSession(id: UUID, text: String, attachments: [ServerAttachmentRef]) async throws -> ServerPromptAccepted {
        try await promptSession(id: id, text: text)
    }

    /// Default for fakes/older transports: the message id is advisory (it
    /// only sharpens echo reconciliation), so dropping it is safe.
    func promptSession(id: UUID, text: String, attachments: [ServerAttachmentRef], messageId: String?) async throws -> ServerPromptAccepted {
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
    func applyServerUpdate() async throws -> ServerUpdateApplied {
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

    func deleteQueuedPrompt(sessionId: UUID, queueItemId: String) async throws {}

    /// Default no-op so fakes and older transports keep compiling; the HTTP
    /// client overrides this with a PATCH carrying the activity stamp.
    func touchSession(id: UUID, updatedAt: Date) async throws {}

    /// Defaults so fakes and older transports keep compiling; the HTTP client
    /// overrides these with the real worktree endpoints.
    func listWorktrees(projectId: UUID) async throws -> [ServerWorktree] { [] }

    /// Notes sync is best-effort; fakes/older servers act notes-less.
    func workspaceNotes(workspaceId: UUID) async throws -> ServerWorkspaceNotes? { nil }
    func saveWorkspaceNotes(workspaceId: UUID, content: String, updatedAt: Date) async throws {}

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
}

public struct CodevisorServerConfig: Equatable, Sendable {
    public static let productionPort = CodevisorAppVariant.productionPort
    public static let developmentPort = CodevisorAppVariant.developmentPort

    public static var localPort: Int {
        CodevisorAppVariant.localServerPort
    }

    public var baseURL: URL
    public var bearerToken: String?

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:\(CodevisorServerConfig.localPort)")!,
        bearerToken: String? = nil
    ) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
    }

    public static let localDefault = CodevisorServerConfig()
}

public struct ServerHealth: Decodable, Equatable, Sendable {
    public var ok: Bool
    public var version: String
    public var database: String
    public var bootId: String? = nil
    public var processId: Int? = nil
    public var appOwned: Bool? = nil
    public var buildNumber: Int? = nil
    public var sourceRevision: String? = nil
    public var serviceManaged: Bool? = nil
    public var migration: ServerMigrationProgress?
}

public struct ServerMigrationProgress: Decodable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var completed: Int
    public var total: Int
    public var error: String?
}

public struct ServerInfo: Decodable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var kind: String
    public var version: String
    public var platform: String
    public var bindHost: String
    public var features: [String]?
}

public struct ServerUpdateInfo: Decodable, Equatable, Sendable {
    public var currentVersion: String
    public var latestVersion: String
    public var updateAvailable: Bool
    public var channel: String
    public var checkedAt: String?
    public var migrationState: String

    public init(
        currentVersion: String,
        latestVersion: String,
        updateAvailable: Bool,
        channel: String,
        checkedAt: String?,
        migrationState: String
    ) {
        self.currentVersion = currentVersion
        self.latestVersion = latestVersion
        self.updateAvailable = updateAvailable
        self.channel = channel
        self.checkedAt = checkedAt
        self.migrationState = migrationState
    }
}

/// Response of `POST /v1/update/apply`.
public struct ServerUpdateApplied: Decodable, Equatable, Sendable {
    public var accepted: Bool
    public var targetVersion: String?
    /// When `accepted` is false, why the server declined — e.g. "busy" while
    /// chats are still running. Absent on older servers and on plain
    /// already-up-to-date responses.
    public var reason: String?

    public init(accepted: Bool, targetVersion: String?, reason: String? = nil) {
        self.accepted = accepted
        self.targetVersion = targetVersion
        self.reason = reason
    }
}

public struct ServerPairingToken: Decodable, Equatable, Sendable {
    public var token: String
    public var createdAt: String
}

public struct ServerHarnessReadiness: Codable, Equatable, Sendable {
    public var state: String
    public var detail: String?
    /// Resolved binary location and probed version for ready harnesses.
    public var path: String?
    public var version: String?

    public init(state: String, detail: String? = nil, path: String? = nil, version: String? = nil) {
        self.state = state
        self.detail = detail
        self.path = path
        self.version = version
    }
}

/// One way the server can install a harness CLI on its machine, mirroring
/// `HarnessInstallMethod` in @codevisor/api.
public struct ServerHarnessInstallMethod: Codable, Equatable, Sendable {
    public var id: String
    public var kind: String
    public var label: String
    /// The exact shell command that would run — shown verbatim before install.
    public var command: String
    public var available: Bool
    public var recommended: Bool

    public init(
        id: String,
        kind: String,
        label: String,
        command: String,
        available: Bool,
        recommended: Bool
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.command = command
        self.available = available
        self.recommended = recommended
    }
}

/// Latest-version knowledge for an installed harness, mirroring
/// `HarnessUpdateInfo` in @codevisor/api.
public struct ServerHarnessUpdateInfo: Codable, Equatable, Sendable {
    public var installedVersion: String?
    public var latestVersion: String?
    public var updateAvailable: Bool
    public var source: String?
    public var installOrigin: String?
    public var channel: String?
    public var checkedAt: String?

    public init(
        installedVersion: String? = nil,
        latestVersion: String? = nil,
        updateAvailable: Bool,
        source: String? = nil,
        installOrigin: String? = nil,
        channel: String? = nil,
        checkedAt: String? = nil
    ) {
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
        self.updateAvailable = updateAvailable
        self.source = source
        self.installOrigin = installOrigin
        self.channel = channel
        self.checkedAt = checkedAt
    }
}

/// Live install/update state for one harness, mirroring
/// `HarnessLifecycleState` in @codevisor/api. `phase` is one of
/// idle/installing/updating/pendingUpdate/failed.
public struct ServerHarnessLifecycleState: Codable, Equatable, Sendable {
    public var phase: String
    public var targetVersion: String?
    public var methodId: String?
    /// Background terminal streaming the operation's output ("Show Output").
    public var terminalId: String?
    public var error: String?
    public var startedAt: String?

    public init(
        phase: String,
        targetVersion: String? = nil,
        methodId: String? = nil,
        terminalId: String? = nil,
        error: String? = nil,
        startedAt: String? = nil
    ) {
        self.phase = phase
        self.targetVersion = targetVersion
        self.methodId = methodId
        self.terminalId = terminalId
        self.error = error
        self.startedAt = startedAt
    }
}

/// A user-defined custom ACP harness spec, mirroring `CustomHarnessSpec` in
/// @codevisor/api. Launched server-side as `command args…` with `env` merged
/// into the spawn environment.
public struct ServerCustomHarnessSpec: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var command: String
    public var args: [String]?
    public var env: [String: String]?

    public init(
        id: String,
        name: String,
        command: String,
        args: [String]? = nil,
        env: [String: String]? = nil
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.args = args
        self.env = env
    }
}

/// Result of the ACP initialize handshake probe ("Test Connection"),
/// mirroring `CustomHarnessTestResult` in @codevisor/api.
public struct ServerCustomHarnessTestResult: Codable, Equatable, Sendable {
    public var ok: Bool
    public var agentName: String?
    public var protocolVersion: Int?
    public var error: String?

    public init(ok: Bool, agentName: String? = nil, protocolVersion: Int? = nil, error: String? = nil) {
        self.ok = ok
        self.agentName = agentName
        self.protocolVersion = protocolVersion
        self.error = error
    }
}

/// Wire wrapper for the custom-harness list routes.
struct ServerCustomHarnessListEnvelope: Codable, Equatable, Sendable {
    var harnesses: [ServerCustomHarnessSpec]
}

/// Dual-install: a desktop app bundling a copy of the harness CLI, with its
/// own Sparkle-fed update state. Mirrors `HarnessBundledApp` in @codevisor/api.
public struct ServerHarnessBundledApp: Codable, Equatable, Sendable {
    public var appName: String
    public var bundlePath: String
    public var installedVersion: String?
    public var latestVersion: String?
    public var updateAvailable: Bool

    public init(
        appName: String,
        bundlePath: String,
        installedVersion: String? = nil,
        latestVersion: String? = nil,
        updateAvailable: Bool
    ) {
        self.appName = appName
        self.bundlePath = bundlePath
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
        self.updateAvailable = updateAvailable
    }
}

/// 202 ack for install/update starts.
public struct ServerHarnessOperationStarted: Codable, Equatable, Sendable {
    public var accepted: Bool
    public var terminalId: String?
    public var queued: Bool?

    public init(accepted: Bool, terminalId: String? = nil, queued: Bool? = nil) {
        self.accepted = accepted
        self.terminalId = terminalId
        self.queued = queued
    }
}

public struct ServerHarness: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var symbolName: String
    public var source: String
    public var launchKind: String
    public var enabled: Bool
    public var desiredEnabled: Bool?
    public var readiness: ServerHarnessReadiness
    public var auth: ServerHarnessAuth?
    /// Copyable shell command that installs the harness CLI; present only for
    /// harnesses with a well-known installer.
    public var installHint: String?
    /// Ways the server can install this harness on its machine. Absent on
    /// servers that predate lifecycle management.
    public var installMethods: [ServerHarnessInstallMethod]?
    /// Latest-version knowledge from the server's periodic update check.
    public var updateInfo: ServerHarnessUpdateInfo?
    /// Live install/update operation state.
    public var lifecycle: ServerHarnessLifecycleState?

    public init(
        id: String,
        name: String,
        symbolName: String,
        source: String,
        launchKind: String,
        enabled: Bool,
        readiness: ServerHarnessReadiness,
        installHint: String? = nil,
        desiredEnabled: Bool? = nil,
        auth: ServerHarnessAuth? = nil,
        installMethods: [ServerHarnessInstallMethod]? = nil,
        updateInfo: ServerHarnessUpdateInfo? = nil,
        lifecycle: ServerHarnessLifecycleState? = nil
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.source = source
        self.launchKind = launchKind
        self.enabled = enabled
        self.desiredEnabled = desiredEnabled
        self.readiness = readiness
        self.installHint = installHint
        self.auth = auth
        self.installMethods = installMethods
        self.updateInfo = updateInfo
        self.lifecycle = lifecycle
    }
}

public struct ServerMcpServer: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var kind: String?
    public var canEdit: Bool?
    public var canRemove: Bool?
    public var transport: String
    public var url: String?
    public var command: String?
    public var args: [String]
    public var headerNames: [String]?
    public var environmentNames: [String]?
    public var enabled: Bool
    public var authType: String
    public var oauthScope: String?
    public var connectionState: String
    public var toolCount: Int
    public var detail: String?
    public var createdAt: String
    public var updatedAt: String
}

public struct ServerBrowserUseConfiguration: Codable, Equatable, Sendable {
    public var preferredBrowser: String?
    public var chromeAvailable: Bool
    public var chromeConnected: Bool
    public var managedAvailable: Bool
    public var developmentExtensionPath: String?

    public init(
        preferredBrowser: String? = nil,
        chromeAvailable: Bool,
        chromeConnected: Bool,
        managedAvailable: Bool,
        developmentExtensionPath: String? = nil
    ) {
        self.preferredBrowser = preferredBrowser
        self.chromeAvailable = chromeAvailable
        self.chromeConnected = chromeConnected
        self.managedAvailable = managedAvailable
        self.developmentExtensionPath = developmentExtensionPath
    }
}

public struct ServerMcpTool: Codable, Equatable, Identifiable, Sendable {
    public var serverId: String
    public var serverName: String
    public var name: String
    public var title: String?
    public var description: String?
    public var id: String { "\(serverId)/\(name)" }
}

public struct ServerMcpOAuthStart: Codable, Equatable, Sendable {
    public var authorizationUrl: String
}

public struct ServerMcpAuthDetection: Codable, Equatable, Sendable {
    public var authType: String
    public var detail: String
    public var suggestedName: String? = nil
}

/// An MCP server registered directly in a harness's own config file. Secret
/// values never leave the server — only env/header names arrive for display.
public struct ServerNativeMcpServer: Codable, Equatable, Identifiable, Sendable {
    public var harnessId: String
    public var harnessName: String
    public var serverName: String
    /// "global" (user-level config) or "project" (committed file, read-only).
    public var scope: String
    public var configPath: String
    public var transport: String
    public var url: String?
    public var command: String?
    public var args: [String]
    public var envNames: [String]
    public var headerNames: [String]
    /// Present only when the harness has a real per-server enable flag.
    public var enabled: Bool?
    public var supportsDisable: Bool
    public var supportsRemove: Bool
    public var identity: String
    public var alreadyManaged: Bool

    public var id: String { "\(harnessId)|\(scope)|\(configPath)|\(serverName)" }

    public init(
        harnessId: String,
        harnessName: String,
        serverName: String,
        scope: String,
        configPath: String,
        transport: String,
        url: String? = nil,
        command: String? = nil,
        args: [String] = [],
        envNames: [String] = [],
        headerNames: [String] = [],
        enabled: Bool? = nil,
        supportsDisable: Bool = false,
        supportsRemove: Bool = false,
        identity: String = "",
        alreadyManaged: Bool = false
    ) {
        self.harnessId = harnessId
        self.harnessName = harnessName
        self.serverName = serverName
        self.scope = scope
        self.configPath = configPath
        self.transport = transport
        self.url = url
        self.command = command
        self.args = args
        self.envNames = envNames
        self.headerNames = headerNames
        self.enabled = enabled
        self.supportsDisable = supportsDisable
        self.supportsRemove = supportsRemove
        self.identity = identity
        self.alreadyManaged = alreadyManaged
    }
}

/// One importable server, coalesced across every harness it was found in.
public struct ServerNativeMcpImportCandidate: Codable, Equatable, Identifiable, Sendable {
    public var identity: String
    public var name: String
    public var transport: String
    public var url: String?
    public var command: String?
    public var args: [String]
    public var foundIn: [String]
    public var alreadyManaged: Bool

    public var id: String { identity }

    public init(
        identity: String,
        name: String,
        transport: String,
        url: String? = nil,
        command: String? = nil,
        args: [String] = [],
        foundIn: [String] = [],
        alreadyManaged: Bool = false
    ) {
        self.identity = identity
        self.name = name
        self.transport = transport
        self.url = url
        self.command = command
        self.args = args
        self.foundIn = foundIn
        self.alreadyManaged = alreadyManaged
    }
}

public struct ServerNativeMcpHarnessServers: Codable, Equatable, Identifiable, Sendable {
    public var harnessId: String
    public var harnessName: String
    /// SF Symbol from the harness catalog; nil from older servers.
    public var harnessSymbol: String?
    public var configPath: String
    public var exists: Bool
    /// Per-harness read/parse failure, surfaced instead of failing the scan.
    public var error: String?
    public var servers: [ServerNativeMcpServer]

    public var id: String { harnessId }

    public init(
        harnessId: String,
        harnessName: String,
        harnessSymbol: String? = nil,
        configPath: String,
        exists: Bool,
        error: String? = nil,
        servers: [ServerNativeMcpServer] = []
    ) {
        self.harnessId = harnessId
        self.harnessName = harnessName
        self.harnessSymbol = harnessSymbol
        self.configPath = configPath
        self.exists = exists
        self.error = error
        self.servers = servers
    }
}

public struct ServerNativeMcpScan: Codable, Equatable, Sendable {
    public var candidates: [ServerNativeMcpImportCandidate]
    public var harnesses: [ServerNativeMcpHarnessServers]

    public init(
        candidates: [ServerNativeMcpImportCandidate] = [],
        harnesses: [ServerNativeMcpHarnessServers] = []
    ) {
        self.candidates = candidates
        self.harnesses = harnesses
    }
}

public struct ServerNativeMcpImportOutcome: Codable, Equatable, Identifiable, Sendable {
    public var identity: String
    /// imported | skipped | failed
    public var status: String
    public var serverId: String?
    public var serverName: String?
    public var detail: String?
    public var warnings: [String]

    public var id: String { identity }

    public init(
        identity: String,
        status: String,
        serverId: String? = nil,
        serverName: String? = nil,
        detail: String? = nil,
        warnings: [String] = []
    ) {
        self.identity = identity
        self.status = status
        self.serverId = serverId
        self.serverName = serverName
        self.detail = detail
        self.warnings = warnings
    }
}

public struct ServerNativeMcpImportResult: Codable, Equatable, Sendable {
    public var outcomes: [ServerNativeMcpImportOutcome]
    /// Post-import rescan for wholesale state replacement.
    public var scan: ServerNativeMcpScan

    public init(outcomes: [ServerNativeMcpImportOutcome] = [], scan: ServerNativeMcpScan = .init()) {
        self.outcomes = outcomes
        self.scan = scan
    }
}

/// A server entry Codevisor removed from a harness config file, parked so
/// the removal can be undone.
public struct ServerNativeMcpRemoval: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var harnessId: String
    public var configPath: String
    public var serverName: String
    public var removedAt: String
    public var restoredAt: String?

    public init(
        id: String,
        harnessId: String,
        configPath: String,
        serverName: String,
        removedAt: String,
        restoredAt: String? = nil
    ) {
        self.id = id
        self.harnessId = harnessId
        self.configPath = configPath
        self.serverName = serverName
        self.removedAt = removedAt
        self.restoredAt = restoredAt
    }
}

public struct ServerRemoveNativeMcpResult: Codable, Equatable, Sendable {
    public var removal: ServerNativeMcpRemoval
    public var scan: ServerNativeMcpScan

    public init(removal: ServerNativeMcpRemoval, scan: ServerNativeMcpScan = .init()) {
        self.removal = removal
        self.scan = scan
    }
}

public struct ServerSkillHarnessInstall: Codable, Equatable, Sendable {
    public var harnessId: String
    /// linked | copied | canonical | notInstalled | broken | conflict
    public var state: String

    public init(harnessId: String, state: String) {
        self.harnessId = harnessId
        self.state = state
    }
}

/// A skill in the canonical ~/.agents/skills store with per-harness installs.
public struct ServerGlobalSkill: Codable, Equatable, Identifiable, Sendable {
    public var name: String
    public var directoryName: String
    public var description: String?
    public var path: String
    public var invalid: Bool?
    public var installs: [ServerSkillHarnessInstall]

    public var id: String { directoryName }

    public init(
        name: String,
        directoryName: String,
        description: String? = nil,
        path: String,
        invalid: Bool? = nil,
        installs: [ServerSkillHarnessInstall] = []
    ) {
        self.name = name
        self.directoryName = directoryName
        self.description = description
        self.path = path
        self.invalid = invalid
        self.installs = installs
    }
}

/// A skill found in a harness's own skills directory that is not a link into
/// the canonical store: an independent copy or a broken link.
public struct ServerHarnessSkill: Codable, Equatable, Identifiable, Sendable {
    public var harnessId: String
    public var directoryName: String
    public var name: String
    public var description: String?
    public var path: String
    /// independent | broken
    public var classification: String
    public var invalid: Bool?
    public var duplicateOf: String?

    public var id: String { "\(harnessId)|\(directoryName)" }

    public init(
        harnessId: String,
        directoryName: String,
        name: String,
        description: String? = nil,
        path: String,
        classification: String,
        invalid: Bool? = nil,
        duplicateOf: String? = nil
    ) {
        self.harnessId = harnessId
        self.directoryName = directoryName
        self.name = name
        self.description = description
        self.path = path
        self.classification = classification
        self.invalid = invalid
        self.duplicateOf = duplicateOf
    }
}

public struct ServerSkillsHarnessGroup: Codable, Equatable, Identifiable, Sendable {
    public var harnessId: String
    public var harnessName: String
    /// SF Symbol from the harness catalog; nil from older servers.
    public var harnessSymbol: String?
    public var skillsDir: String
    public var skills: [ServerHarnessSkill]

    public var id: String { harnessId }

    public init(
        harnessId: String,
        harnessName: String,
        harnessSymbol: String? = nil,
        skillsDir: String,
        skills: [ServerHarnessSkill] = []
    ) {
        self.harnessId = harnessId
        self.harnessName = harnessName
        self.harnessSymbol = harnessSymbol
        self.skillsDir = skillsDir
        self.skills = skills
    }
}

/// One skill offered by a remote source, for the pre-import picker.
public struct ServerRemoteSkillCandidate: Codable, Equatable, Identifiable, Sendable {
    public var name: String
    public var directoryName: String
    public var description: String?
    public var alreadyExists: Bool

    public var id: String { directoryName }

    public init(name: String, directoryName: String, description: String? = nil, alreadyExists: Bool = false) {
        self.name = name
        self.directoryName = directoryName
        self.description = description
        self.alreadyExists = alreadyExists
    }
}

public struct ServerSkillsScan: Codable, Equatable, Sendable {
    public var canonicalDir: String
    public var global: [ServerGlobalSkill]
    public var harnesses: [ServerSkillsHarnessGroup]

    public init(
        canonicalDir: String = "",
        global: [ServerGlobalSkill] = [],
        harnesses: [ServerSkillsHarnessGroup] = []
    ) {
        self.canonicalDir = canonicalDir
        self.global = global
        self.harnesses = harnesses
    }
}

public struct CreateMcpServerBody: Encodable, Equatable, Sendable {
    public var name: String
    public var transport: String
    public var url: String?
    public var command: String?
    public var args: [String]?
    public var env: [String: String]?
    public var headers: [String: String]?
    public var enabled: Bool?
    public var authType: String?
    public var bearerToken: String?
    public var oauthScope: String?
    public var oauthClientId: String?
    public var oauthClientSecret: String?

    public init(
        name: String,
        transport: String,
        url: String? = nil,
        command: String? = nil,
        args: [String]? = nil,
        env: [String: String]? = nil,
        headers: [String: String]? = nil,
        enabled: Bool? = true,
        authType: String? = nil,
        bearerToken: String? = nil,
        oauthScope: String? = nil,
        oauthClientId: String? = nil,
        oauthClientSecret: String? = nil
    ) {
        self.name = name
        self.transport = transport
        self.url = url
        self.command = command
        self.args = args
        self.env = env
        self.headers = headers
        self.enabled = enabled
        self.authType = authType
        self.bearerToken = bearerToken
        self.oauthScope = oauthScope
        self.oauthClientId = oauthClientId
        self.oauthClientSecret = oauthClientSecret
    }
}

public struct UpdateMcpServerBody: Encodable, Equatable, Sendable {
    public var name: String?
    public var url: String?
    public var command: String?
    public var args: [String]?
    public var env: [String: String]?
    public var headers: [String: String]?
    public var removeEnv: [String]?
    public var removeHeaders: [String]?
    public var authType: String?
    public var bearerToken: String?
    public var oauthScope: String?
    public var oauthClientId: String?
    public var oauthClientSecret: String?

    public init(
        name: String? = nil,
        url: String? = nil,
        command: String? = nil,
        args: [String]? = nil,
        env: [String: String]? = nil,
        headers: [String: String]? = nil,
        removeEnv: [String]? = nil,
        removeHeaders: [String]? = nil,
        authType: String? = nil,
        bearerToken: String? = nil,
        oauthScope: String? = nil,
        oauthClientId: String? = nil,
        oauthClientSecret: String? = nil
    ) {
        self.name = name
        self.url = url
        self.command = command
        self.args = args
        self.env = env
        self.headers = headers
        self.removeEnv = removeEnv
        self.removeHeaders = removeHeaders
        self.authType = authType
        self.bearerToken = bearerToken
        self.oauthScope = oauthScope
        self.oauthClientId = oauthClientId
        self.oauthClientSecret = oauthClientSecret
    }
}

public struct ServerHarnessAuthMethod: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var description: String?
    public var kind: String
}

public struct ServerHarnessAccount: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var harnessId: String
    public var profileKind: String
    public var label: String
    public var email: String?
    public var organizationId: String?
    public var authMethod: String?
    public var authState: String
    public var isActive: Bool
    public var canLogin: Bool
    public var canLogout: Bool
    public var lastCheckedAt: String?
    public var detail: String?
}

public struct ServerHarnessAuth: Codable, Equatable, Sendable {
    public var state: String
    public var activeAccountId: String?
    public var accounts: [ServerHarnessAccount]
    public var loginMethods: [ServerHarnessAuthMethod]
    public var supportsMultipleAccounts: Bool
}

public struct ServerHarnessAuthFlow: Codable, Equatable, Sendable {
    public var id: String
    public var accountId: String
    public var kind: String
    public var url: String?
    public var verificationUrl: String?
    public var userCode: String?
    public var terminalId: String?
    public var terminalKey: String?

    /// The session key used by the terminal proxy. Older servers only sent
    /// `terminalId`, so keep that as a compatibility fallback.
    public var terminalAttachKey: String? { terminalKey ?? terminalId }
}

public struct ServerPiAuthProvider: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var methods: [String]
    public var credentialType: String?
}

public struct ServerPiAuthPromptOption: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var description: String?
}

public struct ServerPiAuthPrompt: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var type: String
    public var message: String
    public var placeholder: String?
    public var options: [ServerPiAuthPromptOption]
}

public struct ServerPiAuthEvent: Codable, Equatable, Sendable {
    public var type: String
    public var message: String?
    public var url: String?
    public var userCode: String?
    public var verificationUrl: String?
}

public struct ServerPiAuthFlow: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var providerId: String
    public var state: String
    public var prompt: ServerPiAuthPrompt?
    public var event: ServerPiAuthEvent?
    public var error: String?
}

public struct ServerOpenCodeAuthPromptCondition: Codable, Equatable, Sendable {
    public var key: String
    public var op: String
    public var value: String
}

public struct ServerOpenCodeAuthPromptOption: Codable, Equatable, Identifiable, Sendable {
    public var value: String
    public var label: String
    public var hint: String?
    public var id: String { value }
}

public struct ServerOpenCodeAuthPrompt: Codable, Equatable, Identifiable, Sendable {
    public var type: String
    public var key: String
    public var message: String
    public var placeholder: String?
    public var options: [ServerOpenCodeAuthPromptOption]
    public var when: ServerOpenCodeAuthPromptCondition?
    public var id: String { key }
}

public struct ServerOpenCodeAuthMethod: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var type: String
    public var label: String
    public var prompts: [ServerOpenCodeAuthPrompt]
}

public struct ServerOpenCodeAuthProvider: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var methods: [ServerOpenCodeAuthMethod]
    public var credentialType: String?
}

public struct ServerOpenCodeAuthAuthorization: Codable, Equatable, Sendable {
    public var url: String
    public var method: String
    public var instructions: String
}

public struct ServerOpenCodeAuthFlow: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var accountId: String
    public var providerId: String
    public var state: String
    public var authorization: ServerOpenCodeAuthAuthorization?
    public var error: String?
}

public struct ServerHarnessCapability: Codable, Equatable, Sendable {
    public var harness: ServerHarness
    public var modes: SessionModeState?
    public var configOptions: [SessionConfigOption]
    /// Whether the harness supports persistent session goals (codex goal mode).
    public var supportsGoals: Bool?
}

/// The three wire states of a goal's token budget on update, mirroring the
/// codex double-option: omit the key to keep the current budget, send an
/// explicit `null` to clear it, or send a positive number to set it.
public enum TokenBudgetUpdate: Sendable, Equatable {
    case keep
    case clear
    case set(Int)
}

public struct ServerCapabilities: Codable, Equatable, Sendable {
    public var harnesses: [ServerHarnessCapability]
}

public struct ServerSessionRuntimeMetadata: Codable, Equatable, Sendable {
    public var sessionId: String
    public var modes: SessionModeState?
    public var configOptions: [SessionConfigOption]
    public var supportsGoals: Bool?
}

public struct ServerPromptAccepted: Decodable, Equatable, Sendable {
    public var accepted: Bool
    public var sessionId: String
    public var queueItemId: String?
}

public struct ServerPromptQueueItem: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var sessionId: String
    public var text: String
    public var createdAt: String
    public var updatedAt: String
    public var attachments: [ServerAttachmentRef]?

    init(id: String, sessionId: String, text: String, createdAt: String, updatedAt: String, attachments: [ServerAttachmentRef]? = nil) {
        self.id = id
        self.sessionId = sessionId
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.attachments = attachments
    }
}

public enum ServerAttachmentKind: String, Codable, Equatable, Sendable {
    case image
    case file
}

/// A reference to an uploaded file (`POST /v1/files`); bytes are fetched via
/// `GET /v1/files/:id`.
public struct ServerAttachmentRef: Codable, Identifiable, Equatable, Sendable {
    public var fileId: String
    public var name: String
    public var mimeType: String
    public var sizeBytes: Int
    public var kind: ServerAttachmentKind

    public var id: String { fileId }

    public init(fileId: String, name: String, mimeType: String, sizeBytes: Int, kind: ServerAttachmentKind) {
        self.fileId = fileId
        self.name = name
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.kind = kind
    }
}

public struct ServerFileMetadata: Decodable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var mimeType: String
    public var sizeBytes: Int
    public var sha256: String
    public var kind: ServerAttachmentKind
    public var createdAt: String

    public var attachmentRef: ServerAttachmentRef {
        ServerAttachmentRef(fileId: id, name: name, mimeType: mimeType, sizeBytes: sizeBytes, kind: kind)
    }
}

public struct ServerProjectLocation: Decodable, Equatable, Sendable {
    public var id: String
    public var projectId: String
    public var serverId: String
    public var folderPath: String
    public var createdAt: String
    public var isGitRepository: Bool?
}

public struct ServerFsEntry: Decodable, Equatable, Sendable {
    public var name: String
    public var path: String
    public var isGitRepo: Bool

    public init(name: String, path: String, isGitRepo: Bool) {
        self.name = name
        self.path = path
        self.isGitRepo = isGitRepo
    }
}

public struct ServerFsListing: Decodable, Equatable, Sendable {
    public var path: String
    public var parent: String?
    public var entries: [ServerFsEntry]

    public init(path: String, parent: String?, entries: [ServerFsEntry]) {
        self.path = path
        self.parent = parent
        self.entries = entries
    }
}

public struct ServerProject: Decodable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var isArchived: Bool
    public var symbolName: String
    public var origin: SessionOrigin
    public var createdAt: String
    public var locations: [ServerProjectLocation]
    /// The git remote this project was cloned from, for projects added via
    /// clone-from-git. Absent on older servers and directory-based projects.
    public var repoUrl: String? = nil

    public func project(serverId: String = "local") throws -> Project {
        guard let uuid = UUID(uuidString: id) else {
            throw CodevisorServerClientError.invalidUUID(id)
        }
        return Project(
            id: uuid,
            serverId: serverId,
            name: name,
            isArchived: isArchived,
            symbolName: symbolName,
            origin: origin,
            createdAt: try ServerDateCoding.date(from: createdAt),
            locations: locations.map { location in
                // Stamp the location with the client's machine id, not the
                // server's self-reported id (always "local"). Otherwise
                // `location(for: machineId)` misses on remote machines, so
                // `isGitRepository` (and the folder lookup) silently fall back
                // — which is why worktrees looked disabled on remote repos.
                ProjectLocation(
                    id: location.id,
                    projectId: uuid,
                    serverId: serverId,
                    folderPath: location.folderPath,
                    isGitRepository: location.isGitRepository
                )
            }
        )
    }
}

/// A workspace's synced scratchpad record. `content` is an opaque encoded
/// rich-text document (AttributedString Codable JSON, format-tagged).
public struct ServerWorkspaceNotes: Decodable, Equatable, Sendable {
    public var workspaceId: String
    public var content: String
    public var format: String
    public var updatedAt: String

    /// The LWW stamp as a date (nil if the server sent an unparseable one).
    public var updatedAtDate: Date? {
        try? ServerDateCoding.date(from: updatedAt)
    }
}

public struct ServerWorktree: Decodable, Equatable, Sendable {
    public var id: String
    public var projectId: String
    public var serverId: String
    public var name: String
    public var branch: String
    public var path: String
    public var createdAt: String
}

public struct ServerSessionUsage: Decodable, Equatable, Sendable {
    public var used: Double?
    public var size: Double?
    public var inputTokens: Double?
    public var cachedInputTokens: Double?
    public var outputTokens: Double?
    public var reasoningOutputTokens: Double?
    public var totalTokens: Double?
    public var costAmount: Double?
    public var costCurrency: String?
    public var costKind: String?

    public var sessionUsage: SessionUsage {
        SessionUsage(
            used: used.map(UInt64.init),
            size: size.map(UInt64.init),
            inputTokens: inputTokens.map(UInt64.init),
            cachedInputTokens: cachedInputTokens.map(UInt64.init),
            outputTokens: outputTokens.map(UInt64.init),
            reasoningOutputTokens: reasoningOutputTokens.map(UInt64.init),
            totalTokens: totalTokens.map(UInt64.init),
            cost: costAmount.map {
                SessionCost(
                    amount: $0,
                    currency: costCurrency ?? "USD",
                    kind: costKind.flatMap(SessionCost.Kind.init(rawValue:))
                )
            }
        )
    }
}

public struct ServerHarnessUsageWindow: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var usedPercent: Double
    public var durationMinutes: Double?
    public var resetsAt: String?
}

public struct ServerHarnessUsageCredits: Decodable, Equatable, Sendable {
    public var hasCredits: Bool
    public var unlimited: Bool
    public var balance: String?
}

public struct ServerHarnessUsageLimits: Decodable, Equatable, Sendable {
    public var state: String
    public var harnessId: String
    public var accountId: String?
    public var accountLabel: String?
    public var accountEmail: String?
    public var plan: String?
    public var windows: [ServerHarnessUsageWindow]
    public var credits: ServerHarnessUsageCredits?
    public var detail: String?
    public var fetchedAt: String
}

public struct ServerSession: Decodable, Equatable, Sendable {
    public var id: String
    public var projectId: String
    public var serverId: String
    public var harnessId: String
    public var harnessAccountId: String?
    public var agentSessionId: String?
    public var title: String
    public var origin: SessionOrigin
    public var isArchived: Bool
    public var worktreeName: String?
    public var cwd: String?
    public var configSelections: [String: String]? = nil
    public var createdAt: String
    public var updatedAt: String?
    public var usage: ServerSessionUsage?

    public func chatSession(serverId scopedServerId: String? = nil) throws -> ChatSession {
        guard let uuid = UUID(uuidString: id) else {
            throw CodevisorServerClientError.invalidUUID(id)
        }
        guard let projectUUID = UUID(uuidString: projectId) else {
            throw CodevisorServerClientError.invalidUUID(projectId)
        }
        return ChatSession(
            id: uuid,
            projectId: projectUUID,
            serverId: scopedServerId ?? serverId,
            harnessId: harnessId,
            harnessAccountId: harnessAccountId,
            // The server stores "" for a deferred (not-yet-created) agent;
            // the app's "no agent yet" checks all use nil — normalize at
            // the boundary so both spellings mean the same thing.
            agentSessionId: agentSessionId.flatMap { $0.isEmpty ? nil : $0 },
            title: title,
            origin: origin,
            isArchived: isArchived,
            worktreeName: worktreeName,
            cwd: cwd,
            configSelections: configSelections,
            createdAt: try ServerDateCoding.date(from: createdAt),
            updatedAt: try updatedAt.map(ServerDateCoding.date)
        )
    }
}

public enum ServerConversationRole: String, Decodable, Equatable, Sendable {
    case user
    case assistant
    case system
}

public struct ServerConversationItem: Decodable, Equatable, Sendable {
    public var id: String
    public var role: ServerConversationRole
    public var messageId: String?
    public var text: String
    public var createdAt: String
    public var isGenerating: Bool
    public var attachments: [ServerAttachmentRef]? = nil
}

public struct ServerSessionDetail: Decodable, Equatable, Sendable {
    public var session: ServerSession
    public var conversation: [ServerConversationItem]
    public var promptQueue: [ServerPromptQueueItem]
    public var eventCursor: Int
    public var pendingQuestion: QuestionRequest?
    public var backgroundTasks: [BackgroundTaskInfo]?
    public var goal: SessionGoal?

    public init(
        session: ServerSession,
        conversation: [ServerConversationItem],
        promptQueue: [ServerPromptQueueItem] = [],
        eventCursor: Int,
        pendingQuestion: QuestionRequest? = nil,
        backgroundTasks: [BackgroundTaskInfo]? = nil,
        goal: SessionGoal? = nil
    ) {
        self.session = session
        self.conversation = conversation
        self.promptQueue = promptQueue
        self.eventCursor = eventCursor
        self.pendingQuestion = pendingQuestion
        self.backgroundTasks = backgroundTasks
        self.goal = goal
    }

    enum CodingKeys: String, CodingKey {
        case session
        case conversation
        case promptQueue
        case eventCursor
        case pendingQuestion
        case backgroundTasks
        case goal
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        session = try container.decode(ServerSession.self, forKey: .session)
        conversation = try container.decode([ServerConversationItem].self, forKey: .conversation)
        promptQueue = try container.decodeIfPresent([ServerPromptQueueItem].self, forKey: .promptQueue) ?? []
        eventCursor = try container.decode(Int.self, forKey: .eventCursor)
        pendingQuestion = try container.decodeIfPresent(QuestionRequest.self, forKey: .pendingQuestion)
        backgroundTasks = try container.decodeIfPresent([BackgroundTaskInfo].self, forKey: .backgroundTasks)
        goal = try container.decodeIfPresent(SessionGoal.self, forKey: .goal)
    }
}

public struct ServerTranscriptItem: Decodable, Equatable, Sendable {
    public enum Role: String, Decodable, Equatable, Sendable {
        case user
        case assistant
    }

    public var id: String
    public var sessionId: String
    public var sequence: Int
    public var role: Role
    public var text: String
    public var createdAt: String
    public var updatedAt: String
    public var isGenerating: Bool
    public var hasDetails: Bool
    public var turnId: String?
    public var startedAt: String?
    public var endedAt: String?
    public var stopReason: String?
    public var stopDetail: String?
    public var retryable: Bool?
    public var planDocument: String?
    public var attachments: [ServerAttachmentRef]?
    /// Provider message id of the still-streaming final text span. Present
    /// only while the item is generating so a mid-stream restore can share
    /// identity with the live deltas that continue the same span.
    public var messageId: String?
    public var revision: Int
}

public struct ServerTranscriptPage: Decodable, Equatable, Sendable {
    public var items: [ServerTranscriptItem]
    public var nextBefore: String?
    public var hasMore: Bool
    public var eventCursor: Int
    public var pendingQuestion: QuestionRequest? = nil
    public var backgroundTasks: [BackgroundTaskInfo]? = nil
    public var goal: SessionGoal? = nil
    public var usage: ServerSessionUsage? = nil
}

/// Response of the combined `POST /v1/sessions/:id/open`: the authoritative
/// session record plus the first transcript page, fetched in one round-trip
/// so a chat can paint its history without waiting on discrete calls.
public struct ServerSessionOpenResponse: Decodable, Sendable {
    public var session: ServerSession
    public var transcript: ServerTranscriptPage
}

public struct ServerTranscriptItemDetails: Decodable, Equatable, Sendable {
    public var itemId: String
    public var revision: Int
    public var events: [ServerEventEnvelope]
}

public struct ServerEventEnvelope: Decodable, Equatable, Sendable {
    public var id: Int
    public var globalEventId: Int? = nil
    public var subjectRevision: Int? = nil
    public var serverId: String
    public var kind: String
    public var subjectId: String
    public var createdAt: String
    public var payload: JSONValue
}

public final class CodevisorServerClient: CodevisorServerClienting, @unchecked Sendable {
    /// Foundation defaults WebSocket messages to 1 MiB. Tool results can
    /// legitimately exceed that (for example a broad repository search), so
    /// leave bounded headroom without altering the event payload.
    static let eventWebSocketMaximumMessageSize = 16 * 1024 * 1024
    private let config: CodevisorServerConfig
    private let urlSession: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(
        config: CodevisorServerConfig = .localDefault,
        urlSession: URLSession = .shared
    ) {
        self.config = config
        self.urlSession = urlSession
    }

    public func health() async throws -> ServerHealth {
        try await get("/v1/health")
    }

    public func info() async throws -> ServerInfo {
        try await get("/v1/info")
    }

    /// `refresh` bypasses the server's update-check cache so a banner shown
    /// while the user is looking at a machine reflects the live release
    /// state. Older servers ignore the query parameter.
    public func updateInfo(refresh: Bool = false) async throws -> ServerUpdateInfo {
        try await get(refresh ? "/v1/update?refresh=1" : "/v1/update")
    }

    public func issuePairingToken() async throws -> ServerPairingToken {
        try await send("/v1/auth/pairing-token", method: "POST", body: Optional<EmptyBody>.none)
    }

    public func connectionToken() async throws -> ServerPairingToken {
        try await get("/v1/auth/connection-token")
    }

    public func capabilities(cwd: String) async throws -> ServerCapabilities {
        try await capabilities(cwd: cwd, harnessId: nil)
    }

    public func capabilities(cwd: String, harnessId: String) async throws -> ServerCapabilities {
        try await capabilities(cwd: cwd, harnessId: Optional(harnessId))
    }

    private func capabilities(cwd: String, harnessId: String?) async throws -> ServerCapabilities {
        var components = URLComponents()
        components.path = "/v1/capabilities"
        components.queryItems = [URLQueryItem(name: "cwd", value: cwd)]
        if let harnessId {
            components.queryItems?.append(URLQueryItem(name: "harnessId", value: harnessId))
        }
        guard let path = components.string else {
            throw CodevisorServerClientError.invalidURL("capabilities")
        }
        return try await get(path)
    }

    public func listHarnesses() async throws -> [ServerHarness] {
        try await get("/v1/harnesses")
    }

    public func listHarnessesWithLifecycle() async throws -> [ServerHarness] {
        try await get("/v1/harnesses?include=lifecycle")
    }

    public func rescanHarnesses() async throws -> [ServerHarness] {
        do {
            return try await send(
                "/v1/harnesses/rescan",
                method: "POST",
                body: Optional<EmptyBody>.none
            )
        } catch CodevisorServerClientError.httpStatus(404, _) {
            // Older servers predate the rescan endpoint; a plain list is the
            // best they can do (their PATH stays frozen until they update).
            return try await listHarnesses()
        }
    }

    public func listAgentSessions(harnessId: String) async throws -> [SessionInfo] {
        let encoded = harnessId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? harnessId
        return try await get("/v1/harnesses/\(encoded)/agent-sessions")
    }

    public func setHarnessEnabled(id: String, enabled: Bool) async throws -> ServerHarness {
        try await send(
            "/v1/harnesses/\(id)",
            method: "PATCH",
            body: UpdateHarnessBody(enabled: enabled)
        )
    }

    public func listCustomHarnesses() async throws -> [ServerCustomHarnessSpec] {
        let envelope: ServerCustomHarnessListEnvelope = try await get("/v1/harnesses/custom")
        return envelope.harnesses
    }

    public func replaceCustomHarnesses(_ specs: [ServerCustomHarnessSpec]) async throws -> [ServerHarness] {
        try await send(
            "/v1/harnesses/custom",
            method: "PUT",
            body: ServerCustomHarnessListEnvelope(harnesses: specs)
        )
    }

    public func testCustomHarness(_ spec: ServerCustomHarnessSpec) async throws -> ServerCustomHarnessTestResult {
        try await send("/v1/harnesses/custom/test", method: "POST", body: spec)
    }

    public func installHarness(id: String, methodId: String?) async throws -> ServerHarnessOperationStarted {
        struct InstallBody: Encodable { var methodId: String? }
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return try await send(
            "/v1/harnesses/\(encoded)/install",
            method: "POST",
            body: InstallBody(methodId: methodId)
        )
    }

    public func updateHarness(id: String) async throws -> ServerHarnessOperationStarted {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return try await send(
            "/v1/harnesses/\(encoded)/update",
            method: "POST",
            body: Optional<EmptyBody>.none
        )
    }

    public func bundledAppInfo(harnessId: String) async throws -> ServerHarnessBundledApp? {
        let encoded = harnessId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? harnessId
        do {
            return try await get("/v1/harnesses/\(encoded)/bundled-app")
        } catch CodevisorServerClientError.httpStatus(404, _) {
            return nil
        }
    }

    public func updateBundledApp(harnessId: String) async throws {
        let encoded = harnessId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? harnessId
        let _: ServerHarnessOperationStarted = try await send(
            "/v1/harnesses/\(encoded)/bundled-app/update",
            method: "POST",
            body: Optional<EmptyBody>.none
        )
    }

    public func applyPendingHarnessUpdate(id: String) async throws {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let _: ServerHarnessOperationStarted = try await send(
            "/v1/harnesses/\(encoded)/update/pending/apply",
            method: "POST",
            body: Optional<EmptyBody>.none
        )
    }

    public func cancelPendingHarnessUpdate(id: String) async throws {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        try await sendNoResponse("/v1/harnesses/\(encoded)/update/pending", method: "DELETE")
    }

    public func checkHarnessUpdates() async throws -> [ServerHarness] {
        do {
            return try await send(
                "/v1/harnesses/check-updates",
                method: "POST",
                body: Optional<EmptyBody>.none
            )
        } catch CodevisorServerClientError.httpStatus(404, _), CodevisorServerClientError.httpStatus(501, _) {
            // Older servers predate update checks; the plain list is the best
            // they can do.
            return try await listHarnesses()
        }
    }

    public func refreshHarnessAuth() async throws -> [ServerHarness] {
        try await send("/v1/harnesses/auth/refresh", method: "POST", body: Optional<EmptyBody>.none)
    }

    public func refreshHarnessAuth(harnessId: String) async throws -> ServerHarness {
        let encoded = harnessId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? harnessId
        let refreshed: [ServerHarness] = try await send(
            "/v1/harnesses/auth/refresh?harnessId=\(encoded)",
            method: "POST",
            body: Optional<EmptyBody>.none
        )
        guard let harness = refreshed.first(where: { $0.id == harnessId }) else {
            throw CodevisorServerClientError.invalidResponse
        }
        return harness
    }

    public func listHarnessAccounts(harnessId: String) async throws -> [ServerHarnessAccount] {
        try await get(harnessAccountsPath(harnessId))
    }

    public func createHarnessAccount(harnessId: String, label: String?) async throws -> ServerHarnessAccount {
        try await send(harnessAccountsPath(harnessId), method: "POST", body: HarnessAccountBody(label: label))
    }

    public func renameHarnessAccount(harnessId: String, accountId: String, label: String) async throws -> ServerHarnessAccount {
        try await send(harnessAccountPath(harnessId, accountId), method: "PATCH", body: HarnessAccountBody(label: label))
    }

    public func removeHarnessAccount(harnessId: String, accountId: String) async throws {
        try await sendNoResponse(harnessAccountPath(harnessId, accountId), method: "DELETE")
    }

    public func activateHarnessAccount(harnessId: String, accountId: String) async throws -> [ServerHarnessAccount] {
        try await send("\(harnessAccountPath(harnessId, accountId))/activate", method: "POST", body: Optional<EmptyBody>.none)
    }

    public func probeHarnessAccount(harnessId: String, accountId: String) async throws -> ServerHarnessAccount {
        try await send("\(harnessAccountPath(harnessId, accountId))/auth/probe", method: "POST", body: Optional<EmptyBody>.none)
    }

    public func loginHarnessAccount(harnessId: String, accountId: String, methodId: String?, apiKey: String?) async throws -> ServerHarnessAuthFlow {
        try await send("\(harnessAccountPath(harnessId, accountId))/login", method: "POST", body: HarnessLoginBody(methodId: methodId, apiKey: apiKey))
    }

    public func cancelHarnessLogin(harnessId: String, accountId: String, flowId: String) async throws {
        try await sendNoResponse("\(harnessAccountPath(harnessId, accountId))/login/\(pathComponent(flowId))", method: "DELETE")
    }

    public func logoutHarnessAccount(harnessId: String, accountId: String) async throws -> ServerHarnessAccount {
        try await send("\(harnessAccountPath(harnessId, accountId))/logout", method: "POST", body: Optional<EmptyBody>.none)
    }

    public func listPiAuthProviders() async throws -> [ServerPiAuthProvider] {
        try await get("/v1/harnesses/pi/providers")
    }

    public func startPiAuth(providerId: String, method: String) async throws -> ServerPiAuthFlow {
        try await send(
            "/v1/harnesses/pi/providers/\(pathComponent(providerId))/login",
            method: "POST",
            body: PiAuthStartBody(method: method)
        )
    }

    public func piAuthFlow(id: String) async throws -> ServerPiAuthFlow {
        try await get("/v1/harnesses/pi/auth-flows/\(pathComponent(id))")
    }

    public func answerPiAuthFlow(id: String, value: String) async throws -> ServerPiAuthFlow {
        try await send(
            "/v1/harnesses/pi/auth-flows/\(pathComponent(id))/answer",
            method: "POST",
            body: PiAuthAnswerBody(value: value)
        )
    }

    public func cancelPiAuthFlow(id: String) async throws {
        try await sendNoResponse("/v1/harnesses/pi/auth-flows/\(pathComponent(id))", method: "DELETE")
    }

    public func removePiAuthProvider(id: String) async throws {
        try await sendNoResponse("/v1/harnesses/pi/providers/\(pathComponent(id))", method: "DELETE")
    }

    public func listOpenCodeAuthProviders(accountId: String) async throws -> [ServerOpenCodeAuthProvider] {
        try await get(openCodeProvidersPath(accountId))
    }

    public func startOpenCodeAuth(accountId: String, providerId: String, methodId: String, inputs: [String: String]?, apiKey: String?) async throws -> ServerOpenCodeAuthFlow {
        try await send(
            "\(openCodeProvidersPath(accountId))/\(pathComponent(providerId))/login",
            method: "POST",
            body: OpenCodeAuthStartBody(methodId: methodId, inputs: inputs, apiKey: apiKey)
        )
    }

    public func openCodeAuthFlow(id: String) async throws -> ServerOpenCodeAuthFlow {
        try await get("/v1/harnesses/opencode/auth-flows/\(pathComponent(id))")
    }

    public func answerOpenCodeAuthFlow(id: String, code: String) async throws -> ServerOpenCodeAuthFlow {
        try await send(
            "/v1/harnesses/opencode/auth-flows/\(pathComponent(id))/answer",
            method: "POST",
            body: OpenCodeAuthAnswerBody(code: code)
        )
    }

    public func cancelOpenCodeAuthFlow(id: String) async throws {
        try await sendNoResponse("/v1/harnesses/opencode/auth-flows/\(pathComponent(id))", method: "DELETE")
    }

    public func removeOpenCodeAuthProvider(accountId: String, providerId: String) async throws {
        try await sendNoResponse(
            "\(openCodeProvidersPath(accountId))/\(pathComponent(providerId))",
            method: "DELETE"
        )
    }

    public func listMcpServers() async throws -> [ServerMcpServer] {
        try await get("/v1/mcps")
    }

    public func browserUseConfiguration() async throws -> ServerBrowserUseConfiguration {
        try await get("/v1/browser-use")
    }

    public func setPreferredBrowser(_ preference: String) async throws -> ServerBrowserUseConfiguration {
        try await send(
            "/v1/browser-use",
            method: "PATCH",
            body: UpdateBrowserUseConfigurationBody(preferredBrowser: preference)
        )
    }

    public func installDevelopmentBrowserExtension() async throws -> ServerBrowserUseConfiguration {
        try await send(
            "/v1/browser-use/extension/install",
            method: "POST",
            body: Optional<EmptyBody>.none
        )
    }

    public func openBrowserExtensionFolder() async throws -> ServerBrowserUseConfiguration {
        try await send(
            "/v1/browser-use/extension/folder",
            method: "POST",
            body: Optional<EmptyBody>.none
        )
    }

    public func openBrowserExtensionsPage() async throws -> ServerBrowserUseConfiguration {
        try await send(
            "/v1/browser-use/extension/chrome",
            method: "POST",
            body: Optional<EmptyBody>.none
        )
    }

    public func openBrowserExtensionWebStore() async throws -> ServerBrowserUseConfiguration {
        try await send(
            "/v1/browser-use/extension/web-store",
            method: "POST",
            body: Optional<EmptyBody>.none
        )
    }

    public func browserExtensionArchive() async throws -> URL {
        let data = try await performRaw(
            "/v1/browser-use/extension/archive",
            method: "GET",
            body: nil,
            contentType: nil
        )
        let port = config.baseURL.port.map(String.init) ?? "default"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Codevisor Browser Extension-\(port)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let archive = directory.appendingPathComponent("Codevisor Chrome Extension.zip")
        try data.write(to: archive, options: .atomic)
        return archive
    }

    public func browserExtensionIcon() async throws -> URL {
        let data = try await performRaw(
            "/v1/browser-use/extension/icon",
            method: "GET",
            body: nil,
            contentType: nil
        )
        let port = config.baseURL.port.map(String.init) ?? "default"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Codevisor Browser Extension-\(port)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let icon = directory.appendingPathComponent("Codevisor Browser Extension.png")
        try data.write(to: icon, options: .atomic)
        return icon
    }

    public func detectMcpAuth(url: String) async throws -> ServerMcpAuthDetection {
        try await send(
            "/v1/mcps/detect-auth",
            method: "POST",
            body: DetectMcpAuthBody(url: url)
        )
    }

    public func createMcpServer(_ request: CreateMcpServerBody) async throws -> ServerMcpServer {
        try await send("/v1/mcps", method: "POST", body: request)
    }

    public func updateMcpServer(id: String, request: UpdateMcpServerBody) async throws -> ServerMcpServer {
        try await send("/v1/mcps/\(pathComponent(id))", method: "PATCH", body: request)
    }

    public func setMcpServerEnabled(id: String, enabled: Bool) async throws -> ServerMcpServer {
        try await send(
            "/v1/mcps/\(pathComponent(id))",
            method: "PATCH",
            body: UpdateMcpEnabledBody(enabled: enabled)
        )
    }

    public func connectMcpServer(id: String) async throws -> ServerMcpServer {
        try await send(
            "/v1/mcps/\(pathComponent(id))/connect",
            method: "POST",
            body: Optional<EmptyBody>.none
        )
    }

    public func startMcpOAuth(id: String) async throws -> ServerMcpOAuthStart {
        try await send(
            "/v1/mcps/\(pathComponent(id))/oauth-start",
            method: "POST",
            body: Optional<EmptyBody>.none
        )
    }

    public func disconnectMcpOAuth(id: String) async throws -> ServerMcpServer {
        try await send(
            "/v1/mcps/\(pathComponent(id))/oauth-disconnect",
            method: "POST",
            body: Optional<EmptyBody>.none
        )
    }

    public func removeMcpServer(id: String) async throws {
        try await sendNoResponse("/v1/mcps/\(pathComponent(id))", method: "DELETE")
    }

    public func listMcpTools(id: String) async throws -> [ServerMcpTool] {
        try await get("/v1/mcps/\(pathComponent(id))/tools")
    }

    public func listNativeMcps() async throws -> ServerNativeMcpScan {
        try await get("/v1/native-mcps")
    }

    private struct ImportNativeMcpsBody: Encodable {
        var identities: [String]
    }

    public func importNativeMcps(identities: [String]) async throws -> ServerNativeMcpImportResult {
        try await send(
            "/v1/native-mcps/import",
            method: "POST",
            body: ImportNativeMcpsBody(identities: identities)
        )
    }

    private struct RemoveNativeMcpBody: Encodable {
        var harnessId: String
        var serverName: String
    }

    private struct SetNativeMcpEnabledBody: Encodable {
        var harnessId: String
        var serverName: String
        var enabled: Bool
    }

    public func removeNativeMcp(
        harnessId: String,
        serverName: String
    ) async throws -> ServerRemoveNativeMcpResult {
        try await send(
            "/v1/native-mcps/remove",
            method: "POST",
            body: RemoveNativeMcpBody(harnessId: harnessId, serverName: serverName)
        )
    }

    public func listNativeMcpRemovals() async throws -> [ServerNativeMcpRemoval] {
        try await get("/v1/native-mcps/removals")
    }

    public func restoreNativeMcpRemoval(id: String) async throws -> ServerNativeMcpScan {
        try await send(
            "/v1/native-mcps/removals/\(pathComponent(id))/restore",
            method: "POST",
            body: Optional<EmptyBody>.none
        )
    }

    public func setNativeMcpEnabled(
        harnessId: String,
        serverName: String,
        enabled: Bool
    ) async throws -> ServerNativeMcpScan {
        try await send(
            "/v1/native-mcps/set-enabled",
            method: "POST",
            body: SetNativeMcpEnabledBody(
                harnessId: harnessId,
                serverName: serverName,
                enabled: enabled
            )
        )
    }

    public func listSkills() async throws -> ServerSkillsScan {
        try await get("/v1/skills")
    }

    private struct CreateSkillBody: Encodable {
        var name: String
        var description: String
        var content: String?
    }

    private struct ImportRemoteSkillBody: Encodable {
        var source: String
        var skillNames: [String]?
    }

    private struct DiscoverRemoteSkillsBody: Encodable {
        var source: String
    }

    private struct DiscoverRemoteSkillsResponse: Decodable {
        var skills: [ServerRemoteSkillCandidate]
    }

    private struct ImportSkillBody: Encodable {
        var path: String
    }

    private struct SetSkillInstalledBody: Encodable {
        var installed: Bool
    }

    private struct MakeSkillGlobalBody: Encodable {
        var harnessId: String
        var directoryName: String
    }

    private struct SyncSkillsBody: Encodable {
        var directoryNames: [String]?
    }

    public func createSkill(
        name: String,
        description: String,
        content: String?
    ) async throws -> ServerSkillsScan {
        try await send(
            "/v1/skills",
            method: "POST",
            body: CreateSkillBody(name: name, description: description, content: content)
        )
    }

    public func discoverRemoteSkills(source: String) async throws -> [ServerRemoteSkillCandidate] {
        let response: DiscoverRemoteSkillsResponse = try await send(
            "/v1/skills/discover-remote",
            method: "POST",
            body: DiscoverRemoteSkillsBody(source: source)
        )
        return response.skills
    }

    public func importRemoteSkill(source: String, skillNames: [String]?) async throws -> ServerSkillsScan {
        try await send(
            "/v1/skills/import-remote",
            method: "POST",
            body: ImportRemoteSkillBody(source: source, skillNames: skillNames)
        )
    }

    public func importSkill(path: String) async throws -> ServerSkillsScan {
        try await send("/v1/skills/import", method: "POST", body: ImportSkillBody(path: path))
    }

    public func removeSkill(directoryName: String) async throws -> ServerSkillsScan {
        try await send(
            "/v1/skills/\(pathComponent(directoryName))",
            method: "DELETE",
            body: Optional<EmptyBody>.none
        )
    }

    public func setSkillInstalled(
        directoryName: String,
        harnessId: String,
        installed: Bool
    ) async throws -> ServerSkillsScan {
        try await send(
            "/v1/skills/\(pathComponent(directoryName))/harnesses/\(pathComponent(harnessId))",
            method: "PUT",
            body: SetSkillInstalledBody(installed: installed)
        )
    }

    public func makeSkillGlobal(
        harnessId: String,
        directoryName: String
    ) async throws -> ServerSkillsScan {
        try await send(
            "/v1/skills/make-global",
            method: "POST",
            body: MakeSkillGlobalBody(harnessId: harnessId, directoryName: directoryName)
        )
    }

    public func syncSkills(directoryNames: [String]?) async throws -> ServerSkillsScan {
        try await send(
            "/v1/skills/sync",
            method: "POST",
            body: SyncSkillsBody(directoryNames: directoryNames)
        )
    }

    private func harnessAccountsPath(_ harnessId: String) -> String {
        "/v1/harnesses/\(pathComponent(harnessId))/accounts"
    }

    private func harnessAccountPath(_ harnessId: String, _ accountId: String) -> String {
        "\(harnessAccountsPath(harnessId))/\(pathComponent(accountId))"
    }

    private func openCodeProvidersPath(_ accountId: String) -> String {
        "/v1/harnesses/opencode/accounts/\(pathComponent(accountId))/providers"
    }

    private func pathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    public func listProjects() async throws -> [ServerProject] {
        try await get("/v1/projects")
    }

    public func upsertProject(_ project: Project) async throws -> ServerProject {
        let remoteProjects = try await listProjects()
        // Compare as UUIDs: the server lowercases ids while Swift's
        // uuidString is uppercase — a string comparison never matches, which
        // sent every "update" down the create path (and archiving, whose
        // PATCH therefore never fired, silently reverted).
        if remoteProjects.contains(where: { UUID(uuidString: $0.id) == project.id }) {
            return try await updateProject(project)
        }
        return try await createProject(project)
    }

    public func updateProject(_ project: Project) async throws -> ServerProject {
        try await send(
            "/v1/projects/\(project.id.uuidString)",
            method: "PATCH",
            body: UpdateProjectBody(project: project)
        )
    }

    public func deleteProject(id: UUID) async throws {
        try await sendNoResponse("/v1/projects/\(id.uuidString)", method: "DELETE")
    }

    public func listWorktrees(projectId: UUID) async throws -> [ServerWorktree] {
        try await get("/v1/projects/\(projectId.uuidString)/worktrees")
    }

    public func createWorktree(projectId: UUID, name: String?) async throws -> ServerWorktree {
        try await createWorktree(projectId: projectId, id: nil, name: name)
    }

    public func createWorktree(projectId: UUID, id: String?, name: String?) async throws -> ServerWorktree {
        try await send(
            "/v1/projects/\(projectId.uuidString)/worktrees",
            method: "POST",
            body: CreateWorktreeBody(id: id, name: name)
        )
    }

    public func listDirectory(path: String?, showHidden: Bool) async throws -> ServerFsListing {
        var components = URLComponents()
        components.path = "/v1/fs/list"
        var query: [URLQueryItem] = []
        if let path {
            query.append(URLQueryItem(name: "path", value: path))
        }
        if showHidden {
            query.append(URLQueryItem(name: "showHidden", value: "true"))
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let requestPath = components.string else {
            throw CodevisorServerClientError.invalidURL("fs/list")
        }
        return try await get(requestPath)
    }

    public func createProjectFromGit(id: UUID, url: String, name: String?) async throws -> ServerProject {
        // Clones legitimately run for minutes on large repos; the default
        // request timeout would abort mid-transfer. Send the id in the same
        // (upper) case the client uses everywhere else — session creation
        // looks the project up by that exact string, so a lowercased id here
        // would store a project the client can never address ("not found").
        try await send(
            "/v1/projects/from-git",
            method: "POST",
            body: CreateProjectFromGitBody(id: id.uuidString, url: url, name: name),
            timeout: 1800
        )
    }

    public func listSessions() async throws -> [ServerSession] {
        try await get("/v1/sessions")
    }

    public func sessionDetail(id: UUID) async throws -> ServerSessionDetail {
        try await get("/v1/sessions/\(id.uuidString)")
    }

    public func sessionUsageLimits(id: UUID) async throws -> ServerHarnessUsageLimits {
        try await get("/v1/sessions/\(id.uuidString)/usage-limits")
    }

    public func connectSession(id: UUID) async throws -> ServerSessionRuntimeMetadata? {
        do {
            return try await send(
                "/v1/sessions/\(id.uuidString)/connect",
                method: "POST",
                body: Optional<EmptyBody>.none
            )
        } catch CodevisorServerClientError.httpStatus(404, _) {
            return nil
        }
    }

    public func openSession(
        _ session: ChatSession,
        project: Project?,
        transcriptLimit: Int
    ) async throws -> ServerSessionOpenResponse? {
        do {
            return try await send(
                "/v1/sessions/\(session.id.uuidString)/open",
                method: "POST",
                body: OpenSessionBody(
                    session: session,
                    project: project,
                    transcriptLimit: transcriptLimit
                )
            )
        } catch CodevisorServerClientError.httpStatus(404, _) {
            // Additive protocol compatibility: an older server routes nothing
            // at /open — the caller repeats the work as discrete calls.
            return nil
        }
    }

    public func transcriptPage(id: UUID, before: String?, limit: Int = 32) async throws -> ServerTranscriptPage {
        var components = URLComponents()
        components.path = "/v1/sessions/\(id.uuidString)/transcript"
        components.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let before {
            components.queryItems?.append(URLQueryItem(name: "before", value: before))
        }
        guard let path = components.string else { throw CodevisorServerClientError.invalidURL("transcript") }
        return try await get(path)
    }

    public func transcriptItemDetails(id: UUID, itemId: String) async throws -> ServerTranscriptItemDetails {
        let encoded = itemId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? itemId
        return try await get("/v1/sessions/\(id.uuidString)/transcript/\(encoded)/details")
    }

    public func sessionEvents(id: UUID) async throws -> [ServerEventEnvelope] {
        try await get("/v1/sessions/\(id.uuidString)/events")
    }

    public func promptQueue(id: UUID) async throws -> [ServerPromptQueueItem] {
        try await get("/v1/sessions/\(id.uuidString)/queue")
    }

    public func upsertSession(_ session: ChatSession) async throws -> ServerSession {
        let remoteSessions = try await listSessions()
        // UUID comparison for the same case-mismatch reason as upsertProject.
        if remoteSessions.contains(where: { UUID(uuidString: $0.id) == session.id }) {
            return try await updateSession(session)
        }
        return try await createSession(session)
    }

    public func updateSession(_ session: ChatSession) async throws -> ServerSession {
        try await send(
            "/v1/sessions/\(session.id.uuidString)",
            method: "PATCH",
            body: UpdateSessionBody(session: session)
        )
    }

    /// Marks conversation activity (a finished turn) without touching other
    /// fields — the server orders sessions by this stamp.
    public func touchSession(id: UUID, updatedAt: Date) async throws {
        try await sendNoResponse(
            "/v1/sessions/\(id.uuidString)",
            method: "PATCH",
            body: TouchSessionBody(updatedAt: ServerDateCoding.string(from: updatedAt))
        )
    }

    public func deleteSession(id: UUID) async throws {
        try await sendNoResponse("/v1/sessions/\(id.uuidString)", method: "DELETE")
    }

    public func promptSession(id: UUID, text: String) async throws -> ServerPromptAccepted {
        try await promptSession(id: id, text: text, attachments: [])
    }

    public func promptSession(id: UUID, text: String, attachments: [ServerAttachmentRef]) async throws -> ServerPromptAccepted {
        try await promptSession(id: id, text: text, attachments: attachments, messageId: nil)
    }

    public func promptSession(id: UUID, text: String, attachments: [ServerAttachmentRef], messageId: String?) async throws -> ServerPromptAccepted {
        try await send(
            "/v1/sessions/\(id.uuidString)/prompt",
            method: "POST",
            body: PromptBody(
                text: text,
                attachments: attachments.isEmpty ? nil : attachments,
                messageId: messageId
            )
        )
    }

    public func workspaceNotes(workspaceId: UUID) async throws -> ServerWorkspaceNotes? {
        do {
            return try await get("/v1/workspaces/\(workspaceId.uuidString)/notes")
        } catch CodevisorServerClientError.httpStatus(404, _) {
            return nil
        }
    }

    public func saveWorkspaceNotes(workspaceId: UUID, content: String, updatedAt: Date) async throws {
        try await sendNoResponse(
            "/v1/workspaces/\(workspaceId.uuidString)/notes",
            method: "PUT",
            body: WorkspaceNotesBody(
                content: content,
                updatedAt: ServerDateCoding.string(from: updatedAt)
            )
        )
    }

    public func uploadFile(name: String, mimeType: String, data: Data) async throws -> ServerFileMetadata {
        // Conservative encoding: percent-encode everything non-alphanumeric so
        // names with `&`, `+`, or `=` survive the query round-trip.
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "attachment"
        let response = try await performRaw(
            "/v1/files?name=\(encodedName)",
            method: "POST",
            body: data,
            contentType: mimeType
        )
        return try decoder.decode(ServerFileMetadata.self, from: response)
    }

    public func fileData(id: String) async throws -> Data {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return try await performRaw("/v1/files/\(encoded)", method: "GET", body: nil, contentType: nil)
    }

    public func updateQueuedPrompt(sessionId: UUID, queueItemId: String, text: String) async throws -> ServerPromptQueueItem {
        try await send(
            "/v1/sessions/\(sessionId.uuidString)/queue/\(queueItemId)",
            method: "PATCH",
            body: UpdateQueuedPromptBody(text: text)
        )
    }

    public func deleteQueuedPrompt(sessionId: UUID, queueItemId: String) async throws {
        try await sendNoResponse("/v1/sessions/\(sessionId.uuidString)/queue/\(queueItemId)", method: "DELETE")
    }

    public func cancelSession(id: UUID) async throws {
        try await sendNoResponse(
            "/v1/sessions/\(id.uuidString)/cancel",
            method: "POST",
            body: CancelBody()
        )
    }

    public func setSessionMode(id: UUID, modeId: String) async throws {
        try await sendNoResponse(
            "/v1/sessions/\(id.uuidString)/mode",
            method: "POST",
            body: SetModeBody(modeId: modeId)
        )
    }

    public func setSessionConfig(id: UUID, configId: String, value: String) async throws {
        try await sendNoResponse(
            "/v1/sessions/\(id.uuidString)/config",
            method: "POST",
            body: SetConfigBody(configId: configId, value: value)
        )
    }

    @discardableResult
    public func setSessionGoal(
        id: UUID,
        objective: String?,
        status: GoalStatus?,
        tokenBudget: TokenBudgetUpdate
    ) async throws -> SessionGoal {
        try await send(
            "/v1/sessions/\(id.uuidString)/goal",
            method: "POST",
            body: SetGoalBody(objective: objective, status: status, tokenBudget: tokenBudget)
        )
    }

    public func clearSessionGoal(id: UUID) async throws {
        try await sendNoResponse("/v1/sessions/\(id.uuidString)/goal", method: "DELETE")
    }

    public func answerSessionQuestion(
        id: UUID,
        questionId: String,
        outcome: String,
        answers: [String: QuestionAnswerEntry]?
    ) async throws {
        try await sendNoResponse(
            "/v1/sessions/\(id.uuidString)/questions/\(questionId)/answer",
            method: "POST",
            body: AnswerQuestionBody(outcome: outcome, answers: answers)
        )
    }

    public func requestShutdown() async throws {
        try await sendNoResponse("/v1/shutdown", method: "POST")
    }

    public func applyServerUpdate() async throws -> ServerUpdateApplied {
        try await send("/v1/update/apply", method: "POST", body: Optional<EmptyBody>.none)
    }

    public func eventStream(since: Int = 0) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
        makeEventStream(path: "/v1/events/socket", since: since)
    }

    public func shellEventStream() -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
        // listProjects/listSessions is the snapshot; only events after the
        // socket attaches are needed here.
        makeEventStream(path: "/v1/events/socket", since: Int.max)
    }

    public func sessionEventStream(id: UUID, since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
        makeEventStream(path: "/v1/sessions/\(id.uuidString)/events/socket", since: since)
    }

    private func makeEventStream(
        path: String,
        since: Int
    ) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var cursor = since
                var failures = 0
                while !Task.isCancelled {
                    do {
                        var request = URLRequest(url: try websocketURL(for: "\(path)?since=\(cursor)"))
                        applyAuthorization(to: &request)
                        let socket = urlSession.webSocketTask(with: request)
                        socket.maximumMessageSize = Self.eventWebSocketMaximumMessageSize
                        socket.resume()
                        defer { socket.cancel(with: .goingAway, reason: nil) }

                        while !Task.isCancelled {
                            let message = try await socket.receive()
                            guard let data = Self.data(from: message) else { continue }
                            let event = try decoder.decode(ServerEventEnvelope.self, from: data)
                            // Int.max requests a live-only subscription. Once the
                            // first event arrives, retain its real cursor so a
                            // reconnect can replay anything missed afterward.
                            cursor = cursor == Int.max ? event.id : max(cursor, event.id)
                            failures = 0
                            continuation.yield(event)
                        }
                    } catch {
                        if Task.isCancelled {
                            continuation.finish()
                            return
                        }
                        let failure = error as NSError
                        if failure.domain == NSPOSIXErrorDomain,
                           failure.code == POSIXErrorCode.EMSGSIZE.rawValue {
                            continuation.finish(throwing: error)
                            return
                        }
                        failures += 1
                        Log.server.error(
                            "Event socket connection failed (consecutive failures: \(failures)); reconnecting: \(String(describing: error), privacy: .public)"
                        )
                        try? await Task.sleep(for: Self.eventReconnectDelay(failures: failures))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func eventReconnectDelay(failures: Int) -> Duration {
        let base = min(5_000, 250 * (1 << min(failures, 5)))
        let jitter = Int.random(in: 0...250)
        return .milliseconds(base + jitter)
    }

    private static func data(from message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case let .data(data):
            return data
        case let .string(text):
            return text.data(using: .utf8)
        @unknown default:
            return nil
        }
    }

    private func createProject(_ project: Project) async throws -> ServerProject {
        try await send(
            "/v1/projects",
            method: "POST",
            body: CreateProjectBody(project: project)
        )
    }

    private func createSession(_ session: ChatSession) async throws -> ServerSession {
        try await send(
            "/v1/sessions",
            method: "POST",
            body: CreateSessionBody(session: session)
        )
    }

    private func get<Response: Decodable>(_ path: String) async throws -> Response {
        try await send(path, method: "GET", body: Optional<EmptyBody>.none)
    }

    private func send<Response: Decodable, Body: Encodable>(
        _ path: String,
        method: String,
        body: Body?,
        timeout: TimeInterval? = nil
    ) async throws -> Response {
        let data = try await perform(path, method: method, body: body, timeout: timeout)
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw error
        }
    }

    private func sendNoResponse(_ path: String, method: String) async throws {
        try await sendNoResponse(path, method: method, body: Optional<EmptyBody>.none)
    }

    private func sendNoResponse<Body: Encodable>(
        _ path: String,
        method: String,
        body: Body?
    ) async throws {
        _ = try await perform(path, method: method, body: body)
    }

    @discardableResult
    private func perform<Body: Encodable>(
        _ path: String,
        method: String,
        body: Body?,
        timeout: TimeInterval? = nil
    ) async throws -> Data {
        var request = URLRequest(url: try url(for: path))
        request.httpMethod = method
        if let timeout {
            request.timeoutInterval = timeout
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyAuthorization(to: &request)
        if let body {
            request.httpBody = try encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodevisorServerClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw CodevisorServerClientError.httpStatus(httpResponse.statusCode, message)
        }
        return data
    }

    /// Sibling of `perform` for raw (non-JSON) bodies and responses — file
    /// uploads and downloads.
    private func performRaw(
        _ path: String,
        method: String,
        body: Data?,
        contentType: String?
    ) async throws -> Data {
        var request = URLRequest(url: try url(for: path))
        request.httpMethod = method
        applyAuthorization(to: &request)
        if let body {
            request.httpBody = body
        }
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodevisorServerClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw CodevisorServerClientError.httpStatus(httpResponse.statusCode, message)
        }
        return data
    }

    private func applyAuthorization(to request: inout URLRequest) {
        guard let bearerToken = config.bearerToken else { return }
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
    }

    private func url(for path: String) throws -> URL {
        let trimmedBase = config.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmedBase)\(path)") else {
            throw CodevisorServerClientError.invalidURL(path)
        }
        return url
    }

    private func websocketURL(for path: String) throws -> URL {
        let baseURL = try url(for: path)
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw CodevisorServerClientError.invalidURL(path)
        }
        switch components.scheme {
        case "http":
            components.scheme = "ws"
        case "https":
            components.scheme = "wss"
        default:
            break
        }
        guard let url = components.url else {
            throw CodevisorServerClientError.invalidURL(path)
        }
        return url
    }
}

private enum ServerDateCoding {
    static func string(from date: Date) -> String {
        formatter(includeFractionalSeconds: true).string(from: date)
    }

    static func date(from string: String) throws -> Date {
        if let date = formatter(includeFractionalSeconds: true).date(from: string) {
            return date
        }
        if let date = formatter(includeFractionalSeconds: false).date(from: string) {
            return date
        }
        throw CodevisorServerClientError.invalidDate(string)
    }

    private static func formatter(includeFractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = includeFractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }
}

private struct EmptyBody: Encodable {}

private struct WorkspaceNotesBody: Encodable {
    var content: String
    var format = "attributed-string-v1"
    var updatedAt: String
}

private struct PromptBody: Encodable {
    var text: String
    var clientActionId = UUID().uuidString
    var attachments: [ServerAttachmentRef]?
    /// The optimistic user message's id (see the protocol's doc).
    var messageId: String?
}

private struct UpdateQueuedPromptBody: Encodable {
    var text: String
}

private struct CancelBody: Encodable {
    var clientActionId = UUID().uuidString
}

private struct SetModeBody: Encodable {
    var modeId: String
    var clientActionId = UUID().uuidString
}

private struct SetConfigBody: Encodable {
    var configId: String
    var value: String
    var clientActionId = UUID().uuidString
}

/// Custom encoding because synthesized Codable cannot express the token-budget
/// double-option: `.keep` omits the key, `.clear` encodes a literal `null`,
/// `.set` encodes the number. Internal (not private) so tests can pin the
/// wire shape.
struct SetGoalBody: Encodable {
    var objective: String?
    var status: GoalStatus?
    var tokenBudget: TokenBudgetUpdate
    var clientActionId = UUID().uuidString

    private enum Keys: String, CodingKey {
        case objective, status, tokenBudget, clientActionId
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encodeIfPresent(objective, forKey: .objective)
        try container.encodeIfPresent(status, forKey: .status)
        switch tokenBudget {
        case .keep:
            break
        case .clear:
            try container.encodeNil(forKey: .tokenBudget)
        case let .set(budget):
            try container.encode(budget, forKey: .tokenBudget)
        }
        try container.encode(clientActionId, forKey: .clientActionId)
    }
}

private struct AnswerQuestionBody: Encodable {
    var outcome: String
    var answers: [String: QuestionAnswerEntry]?
    var clientActionId = UUID().uuidString
}

private struct UpdateHarnessBody: Encodable {
    var enabled: Bool
}

private struct UpdateMcpEnabledBody: Encodable {
    var enabled: Bool
}

private struct UpdateBrowserUseConfigurationBody: Encodable {
    var preferredBrowser: String
}

private struct DetectMcpAuthBody: Encodable {
    var url: String
}

private struct CreateProjectBody: Encodable {
    var id: String
    var folderPath: String
    var name: String
    var isArchived: Bool
    var symbolName: String
    var origin: SessionOrigin
    var createdAt: String

    init(project: Project) {
        id = project.id.uuidString
        folderPath = project.folderURL.path
        name = project.name
        isArchived = project.isArchived
        symbolName = project.symbolName
        origin = project.origin
        createdAt = ServerDateCoding.string(from: project.createdAt)
    }
}

private struct UpdateProjectBody: Encodable {
    var name: String
    var isArchived: Bool
    var symbolName: String

    init(project: Project) {
        name = project.name
        isArchived = project.isArchived
        symbolName = project.symbolName
    }
}

private struct CreateSessionBody: Encodable {
    var id: String
    var projectId: String
    var harnessId: String
    var harnessAccountId: String?
    var agentSessionId: String?
    var title: String
    var origin: SessionOrigin
    var isArchived: Bool
    var worktreeName: String?
    var createdAt: String
    var updatedAt: String?
    /// True for sessions that don't have an agent yet: without it the server
    /// spawns the agent AT CREATE with the cwd derived at that moment, which
    /// pins eagerly-created chats to the project root — a worktree chosen in
    /// the composer afterwards could never move it. Deferred agents are
    /// created lazily on the first prompt, from the CURRENT worktree name.
    var deferAgentSession: Bool?

    init(session: ChatSession) {
        id = session.id.uuidString
        projectId = session.projectId.uuidString
        harnessId = session.harnessId
        harnessAccountId = session.harnessAccountId
        agentSessionId = session.agentSessionId
        title = session.title
        origin = session.origin
        isArchived = session.isArchived
        worktreeName = session.worktreeName
        createdAt = ServerDateCoding.string(from: session.createdAt)
        updatedAt = session.updatedAt.map(ServerDateCoding.string)
        deferAgentSession = session.agentSessionId == nil ? true : nil
    }
}

private struct HarnessAccountBody: Encodable { var label: String? }
private struct HarnessLoginBody: Encodable {
    var methodId: String?
    var apiKey: String?
}
private struct PiAuthStartBody: Encodable { var method: String }
private struct PiAuthAnswerBody: Encodable { var value: String }
private struct OpenCodeAuthStartBody: Encodable {
    var methodId: String
    var inputs: [String: String]?
    var apiKey: String?
}
private struct OpenCodeAuthAnswerBody: Encodable { var code: String }

private struct CreateWorktreeBody: Encodable {
    var id: String?
    var name: String?
}

private struct CreateProjectFromGitBody: Encodable {
    var id: String
    var url: String
    var name: String?
}

private struct UpdateSessionBody: Encodable {
    var agentSessionId: String?
    var isArchived: Bool
    var title: String
    /// Sessions created EAGERLY (before their worktree exists) get the
    /// worktree onto the server record through this PATCH — POST
    /// /v1/sessions is create-or-return, so a later create can't. The
    /// server keeps its current value when nil (no clobbering).
    var worktreeName: String?
    /// Same eager-session gap for the harness: the record is created with
    /// harnessId "" before the composer's choice, and the deferred agent
    /// must start under the harness/account picked at first send. Empty
    /// maps to nil so an unset choice never clobbers the server's value.
    var harnessId: String?
    var harnessAccountId: String?

    init(session: ChatSession) {
        agentSessionId = session.agentSessionId
        isArchived = session.isArchived
        title = session.title
        worktreeName = session.worktreeName
        harnessId = session.harnessId.isEmpty ? nil : session.harnessId
        harnessAccountId = session.harnessAccountId
    }
}

private struct TouchSessionBody: Encodable {
    var updatedAt: String
}

/// Mirrors the legacy discrete open sequence in one payload: `session` is
/// the create-if-missing snapshot, `update` carries the same fields the
/// discrete PATCH used to apply to an existing record, and `project` is
/// created only when the server doesn't know it yet.
private struct OpenSessionBody: Encodable {
    var project: CreateProjectBody?
    var session: CreateSessionBody
    var update: UpdateSessionBody
    var transcriptLimit: Int

    init(session: ChatSession, project: Project?, transcriptLimit: Int) {
        self.project = project.map(CreateProjectBody.init(project:))
        self.session = CreateSessionBody(session: session)
        self.update = UpdateSessionBody(session: session)
        self.transcriptLimit = transcriptLimit
    }
}
