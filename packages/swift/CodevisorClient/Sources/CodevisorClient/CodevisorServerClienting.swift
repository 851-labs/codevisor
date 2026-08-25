import ACPKit
import CodevisorProtocol
import Foundation

public protocol CodevisorServerClienting: Sendable {
    func health() async throws -> ServerHealth
    func info() async throws -> ServerInfo
    /// This machine's cloud registration (`GET /v1/cloud`).
    func cloudRegistration() async throws -> ServerCloudRegistration
    /// Registers the machine on the account behind `sessionToken` and returns
    /// the new cloud device id (`POST /v1/cloud/connect`).
    func connectCloud(serverURL: URL, sessionToken: String) async throws -> String
    /// Stops the machine's cloud connection and forgets its credential
    /// (`POST /v1/cloud/disconnect`).
    func disconnectCloud() async throws
    /// The machine's view of its tailnet, for clients that can't enumerate
    /// peers themselves (iOS). `available` is false when the machine has no
    /// running Tailscale.
    func tailnetPeers() async throws -> ServerTailnetPeers
    /// `refresh` bypasses the server's update-check cache; `channel` selects
    /// which release feed the server consults (older servers ignore both).
    func updateInfo(refresh: Bool, channel: ServerUpdateChannel) async throws -> ServerUpdateInfo
    /// The machine's config-plane replica for a namespace (@codevisor/sync).
    func syncDocument(namespace: String) async throws -> ServerSyncDocument
    /// Merges entries into the machine's replica; the response is the merged
    /// document, so one round trip both pushes and pulls.
    func mergeSyncDocument(
        namespace: String,
        entries: [ServerSyncEntry]
    ) async throws -> ServerSyncDocument
    /// Runs one skills reconcile pass on the machine and reports what it
    /// published, applied, removed — and which blobs it still needs.
    func reconcileSkillsSync() async throws -> ServerSkillsSyncStatus
    /// Runs one MCP-definitions reconcile pass on the machine.
    func reconcileMcpsSync() async throws -> ServerMcpSyncStatus
    /// One harness-plane reconcile pass (enabled set, desired installs,
    /// custom specs) against the machine's replica.
    func reconcileHarnessesSync() async throws -> ServerHarnessSyncStatus
    /// Publishes the machine's harness-account roster (metadata only).
    func publishAccountsSync() async throws
    /// Raw config-plane blob transfer, for ferrying skill archives between
    /// machines.
    func syncBlob(id: String) async throws -> Data
    func putSyncBlob(id: String, bytes: Data) async throws
    /// Whether the machine participates in the config plane at all —
    /// server-enforced; every sync surface refuses while this is off.
    func syncParticipation() async throws -> ServerSyncParticipation
    func setSyncParticipation(enabled: Bool) async throws -> ServerSyncParticipation
    func issuePairingToken() async throws -> ServerPairingToken
    /// The machine's stable connection token (unchanged across restarts and
    /// updates until rotated). Preferred over `issuePairingToken` for showing
    /// a token to copy, so it stays consistent.
    func connectionToken() async throws -> ServerPairingToken
    func capabilities(cwd: String) async throws -> ServerCapabilities
    /// Inspects only one known harness. Existing chats use this overload so
    /// unrelated agents never enter their loading path.
    func capabilities(cwd: String, harnessId: String) async throws -> ServerCapabilities
    /// Resolves a draft's dependent configuration against a temporary
    /// inspection session. Model is applied first server-side, then any still
    /// compatible reasoning, speed, or harness-specific selections.
    func capabilities(
        cwd: String,
        harnessId: String,
        configSelections: [String: String]
    ) async throws -> ServerCapabilities
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
    func loginHarnessAccount(
        harnessId: String, accountId: String, methodId: String?, apiKey: String?
    ) async throws -> ServerHarnessAuthFlow
    func cancelHarnessLogin(harnessId: String, accountId: String, flowId: String) async throws
    func logoutHarnessAccount(harnessId: String, accountId: String) async throws -> ServerHarnessAccount
    func listPiAuthProviders() async throws -> [ServerPiAuthProvider]
    func startPiAuth(providerId: String, method: String) async throws -> ServerPiAuthFlow
    func piAuthFlow(id: String) async throws -> ServerPiAuthFlow
    func answerPiAuthFlow(id: String, value: String) async throws -> ServerPiAuthFlow
    func cancelPiAuthFlow(id: String) async throws
    func removePiAuthProvider(id: String) async throws
    func listOpenCodeAuthProviders(accountId: String) async throws -> [ServerOpenCodeAuthProvider]
    func startOpenCodeAuth(
        accountId: String, providerId: String, methodId: String, inputs: [String: String]?, apiKey: String?
    ) async throws -> ServerOpenCodeAuthFlow
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
    /// Plugins installed on this machine (`GET /v1/plugins`). Empty on
    /// servers without the plugins feature.
    func listPlugins() async throws -> [ServerPluginSummary]
    /// Explicit registry-update state for every installed plugin.
    func listPluginUpdates() async throws -> [ServerPluginUpdateStatus]
    /// Stage and validate one exact candidate for review before applying it.
    func preparePluginUpdate(pluginId: String) async throws -> ServerPluginUpdatePlan
    /// Atomically apply the already-reviewed staged plan.
    func applyPluginUpdate(pluginId: String, planId: String) async throws -> ServerPluginSummary
    /// Fetches plugin or pane artwork. The server accepts SVG/PNG/WebP from
    /// the plugin process and returns a normalized PNG to clients.
    func pluginIcon(pluginId: String, paneType: String?) async throws -> ServerPluginIconAsset
    /// Issues a short-lived pane token and returns the server-relative pane
    /// URL to load in a webview
    /// (`POST /v1/plugins/:pluginId/panes/:paneId/token`).
    func issuePluginPaneToken(
        pluginId: String,
        paneId: String,
        paneType: String,
        workspaceId: String?,
        cwd: String?,
        themeMode: String?
    ) async throws -> ServerPluginPaneTokenResponse
    /// The public plugin registry index, fetched and cached by the machine so
    /// clients never talk to the cloud themselves
    /// (`GET /v1/plugins/registry`). `query` filters entries server-side.
    func fetchPluginRegistry(query: String?) async throws -> ServerPluginRegistryIndex
    /// Stage a plugin source and describe what installing it would run —
    /// the consent step's data (`POST /v1/plugins/discover-remote`).
    func discoverRemotePlugin(source: String) async throws -> ServerPluginRemoteDiscovery
    /// Install (or update a managed install of) the plugin the source
    /// provides (`POST /v1/plugins/import-remote`).
    func importRemotePlugin(source: String) async throws -> ServerPluginSummary
    /// Dev mode: symlink a local plugin directory on the server's machine
    /// into the plugins root (`POST /v1/plugins/link`).
    func linkPlugin(path: String) async throws -> ServerPluginSummary
    /// Uninstall a managed plugin and return the updated list
    /// (`DELETE /v1/plugins/:pluginId`).
    func removePlugin(pluginId: String) async throws -> [ServerPluginSummary]
    /// Stop and immediately relaunch the plugin, clearing its crash state
    /// (`POST /v1/plugins/:pluginId/restart`).
    func restartPlugin(pluginId: String) async throws -> ServerPluginSummary
    /// Restore the retained pre-update code/data snapshot.
    func restorePlugin(pluginId: String) async throws -> ServerPluginSummary
    /// Persistently enable or disable plugin runtime and capabilities.
    func setPluginEnabled(pluginId: String, enabled: Bool) async throws -> ServerPluginSummary
    func listProjects() async throws -> [ServerProject]
    func upsertProject(_ project: Project) async throws -> ServerProject
    func updateProject(_ project: Project) async throws -> ServerProject
    func deleteProject(id: UUID) async throws
    func listProjectGitBranches(projectId: UUID) async throws -> [ServerProjectGitBranch]
    func updateProjectWorktreeBase(
        id: UUID,
        worktreeBase: ProjectWorktreeBase?
    ) async throws -> ServerProject
    /// Creates the hidden backing project for a brand-new scratch workspace:
    /// the server allocates a memorable name, creates its empty folder under
    /// ~/codevisor/workspaces, and registers a project pointing at it. The
    /// client-supplied id makes creation idempotent per workspace.
    func createScratchProject(id: UUID) async throws -> ServerProject
    /// Moves a not-yet-started session to another project (and optionally a
    /// worktree of it). Only valid while the session's agent hasn't started;
    /// the server re-derives the session cwd from the new project.
    func moveSession(id: UUID, projectId: UUID, worktreeName: String?) async throws -> ServerSession
    func listWorktrees(projectId: UUID) async throws -> [ServerWorktree]
    /// Server-owned workspace metadata. Nil means the connected server
    /// predates workspace snapshots; callers must preserve their local data.
    func listWorkspaces() async throws -> [ServerWorkspace]?
    /// Coherent workspace and pane registry. Nil means the connected server
    /// predates the combined snapshot endpoint.
    func workspaceSnapshot() async throws -> ServerWorkspaceSnapshot?
    /// Creates or updates a server-owned workspace identity. Nil means the
    /// connected server predates workspace snapshots.
    func upsertWorkspace(_ workspace: ServerWorkspace) async throws -> ServerWorkspace?
    /// Nil means the connected server predates explicit pane identity.
    func listWorkspacePanes() async throws -> [ServerWorkspacePane]?
    /// Nil means the connected server predates explicit pane mutations.
    func upsertWorkspacePane(_ pane: ServerWorkspacePane) async throws -> ServerWorkspacePane?
    /// Atomically converts this exact pane to a chat and assigns the session.
    /// Nil means the connected server predates atomic pane promotion.
    func promoteWorkspacePaneToChat(
        _ pane: ServerWorkspacePane,
        session: ChatSession
    ) async throws -> ServerWorkspacePanePromotion?
    func deleteWorkspacePane(workspaceId: UUID, paneId: UUID) async throws
    /// Atomically closes a pane. The returned pane is the same identity
    /// converted to New Tab when it was the workspace's final pane.
    func closeWorkspacePane(workspaceId: UUID, paneId: UUID) async throws -> ServerWorkspacePane?
    /// Mirrors a workspace's archived flag so other devices — and the
    /// server's own cascade to the workspace's chats — see it.
    func setWorkspaceArchived(id: UUID, isArchived: Bool) async throws
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
    /// Workspace-aware open used by native clients. Making this a protocol
    /// requirement is essential: calls travel through an existential client,
    /// where an extension-only overload would statically choose the legacy
    /// implementation and silently discard the workspace id.
    func openSession(
        _ session: ChatSession,
        project: Project?,
        workspaceId: UUID?,
        transcriptLimit: Int
    ) async throws -> ServerSessionOpenResponse?
    func transcriptPage(id: UUID, before: String?, limit: Int) async throws -> ServerTranscriptPage
    func transcriptItemDetails(id: UUID, itemId: String) async throws -> ServerTranscriptItemDetails
    func promptQueue(id: UUID) async throws -> [ServerPromptQueueItem]
    func sessionEvents(id: UUID) async throws -> [ServerEventEnvelope]
    func upsertSession(_ session: ChatSession) async throws -> ServerSession
    func upsertSession(_ session: ChatSession, workspaceId: UUID?) async throws -> ServerSession
    func updateSession(_ session: ChatSession) async throws -> ServerSession
    func markSessionRead(id: UUID, throughSequence: Int) async throws -> ServerSession?
    func markSessionUnread(id: UUID) async throws -> ServerSession?
    func clearSessionPlanApproval(id: UUID) async throws
    func deleteSession(id: UUID) async throws
    func promptSession(id: UUID, text: String) async throws -> ServerPromptAccepted
    func promptSession(id: UUID, text: String, attachments: [ServerAttachmentRef]) async throws -> ServerPromptAccepted
    /// `messageId` is the CLIENT's id for its optimistic user message; the
    /// server adopts it as the queue item id, so the user echo comes back
    /// with the same id and reconciles by identity.
    func promptSession(
        id: UUID, text: String, attachments: [ServerAttachmentRef], messageId: String?
    ) async throws -> ServerPromptAccepted
    func uploadFile(name: String, mimeType: String, data: Data) async throws -> ServerFileMetadata
    func fileData(id: String) async throws -> Data
    /// Reads a live file from this machine. Relative paths are resolved by the
    /// server against the specified session's authoritative working directory.
    func fileData(sessionId: UUID, path: String) async throws -> Data
    /// Returns a cheap validator for a live file. Nil keeps compatibility with
    /// servers/transports that predate HEAD metadata for filesystem previews.
    func fileVersion(sessionId: UUID, path: String) async throws -> String?
    func updateQueuedPrompt(sessionId: UUID, queueItemId: String, text: String) async throws -> ServerPromptQueueItem
    func reorderQueuedPrompts(
        sessionId: UUID,
        queueItemIds: [String]
    ) async throws -> [ServerPromptQueueItem]
    func deleteQueuedPrompt(sessionId: UUID, queueItemId: String) async throws
    func cancelSession(id: UUID) async throws
    func setSessionMode(id: UUID, modeId: String) async throws
    func setSessionConfig(id: UUID, configId: String, value: String) async throws
    /// Newer servers return the complete resolved option set with the config
    /// acknowledgement so model-dependent controls can update atomically.
    func setSessionConfigAndReturnOptions(
        id: UUID,
        configId: String,
        value: String
    ) async throws -> [SessionConfigOption]?
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
    func applyServerUpdate(channel: ServerUpdateChannel) async throws -> ServerUpdateApplied
    func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error>
    /// Project/session metadata changes after a freshly loaded shell snapshot.
    func shellEventStream() -> AsyncThrowingStream<ServerEventEnvelope, any Error>
    /// `shellEventStream()`, but events whose kind is not in `handledKinds`
    /// are dropped inside the stream's own (non-main) task. The global socket
    /// carries every `session.output` token chunk of every session; without
    /// this filter each one is fully decoded and hopped onto the consumer's
    /// actor just to be discarded.
    func shellEventStream(handledKinds: Set<String>) -> AsyncThrowingStream<ServerEventEnvelope, any Error>
    func latestShellEventCursor() async throws -> Int
    func shellEventStream(
        since: Int,
        handledKinds: Set<String>
    ) -> AsyncThrowingStream<ServerEventEnvelope, any Error>
    /// Session-scoped sequence and replay. Unlike the machine stream, `since`
    /// is meaningful only within this session.
    func sessionEventStream(id: UUID, since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error>
}
