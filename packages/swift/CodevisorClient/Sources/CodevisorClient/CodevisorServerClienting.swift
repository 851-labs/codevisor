import ACPKit
import CodevisorProtocol
import Foundation
import TranscriptKit

public protocol CodevisorServerClienting: BrowserStateClienting, BrowserFaviconClienting, SimulatorClienting {
  func sharedHarnessAccount(
    harnessId: String, request: ServerSharedHarnessAccountRequest
  ) async throws -> ServerSharedHarnessAccountResponse
  func screenSharing(_ request: ServerScreenSharingRequest) async throws -> ServerScreenSharingReply
  func screenSharingVNCSocket(displayId: String) throws -> any ServerWebSocketConnecting
  func livePreviewSocket(sessionId: UUID) throws -> any ServerWebSocketConnecting
  func exchangeBrowserCookies(_ mutations: [BrowserCookieMutation]) async throws -> BrowserCookieSnapshot
  func browserNavigation(paneId: UUID) async throws -> BrowserNavigation?
  func publishBrowserNavigation(paneId: UUID, navigation: BrowserNavigation) async throws
  func browserFavicon(sha256: String) async throws -> Data?
  func publishBrowserFavicon(sha256: String, png: Data) async throws
  func browserProxySession() async throws -> ServerBrowserProxySession
  func browserProxyFailure(authority: String) async throws -> String?
  func health() async throws -> ServerHealth
  func info() async throws -> ServerInfo
  func cloudRegistration() async throws -> ServerCloudRegistration
  func connectCloud(serverURL: URL, sessionToken: String) async throws -> String
  func connectCloud(
    serverURL: URL,
    sessionToken: String,
    managedBy: String,
    machineName: String?
  ) async throws -> String
  func disconnectCloud() async throws
  func updateInfo(refresh: Bool, channel: ServerUpdateChannel) async throws -> ServerUpdateInfo
  func mergeSyncDocument(
    namespace: String,
    entries: [ServerSyncEntry]
  ) async throws -> ServerSyncDocument
  func reconcileSkillsSync() async throws -> ServerSkillsSyncStatus
  func reconcileMcpsSync() async throws -> ServerMcpSyncStatus
  func reconcileHarnessesSync() async throws -> ServerHarnessSyncStatus
  func reconcileCredentialsSync() async throws -> JSONValue
  func publishAccountsSync() async throws
  func syncBlob(id: String) async throws -> Data
  func putSyncBlob(id: String, bytes: Data) async throws
  func capabilities(cwd: String) async throws -> ServerCapabilities
  func capabilities(cwd: String, harnessId: String) async throws -> ServerCapabilities
  func capabilities(
    cwd: String,
    harnessId: String,
    configSelections: [String: String]
  ) async throws -> ServerCapabilities
  func listHarnesses() async throws -> [ServerHarness]
  func listHarnessesWithLifecycle() async throws -> [ServerHarness]
  func rescanHarnesses() async throws -> [ServerHarness]
  func listAgentSessions(harnessId: String) async throws -> [SessionInfo]
  func installHarness(id: String, methodId: String?) async throws -> ServerHarnessOperationStarted
  func updateHarness(id: String) async throws -> ServerHarnessOperationStarted
  func bundledAppInfo(harnessId: String) async throws -> ServerHarnessBundledApp?
  func updateBundledApp(harnessId: String) async throws
  func checkHarnessUpdates(harnessIds: [String]?) async throws -> [ServerHarness]
  func refreshHarnessAuth() async throws -> [ServerHarness]
  func settleHarnessAuth() async throws -> [ServerHarness]
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
  func answerHarnessLogin(
    harnessId: String, accountId: String, flowId: String, code: String
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
  func startMcpOAuth(id: String) async throws -> ServerMcpOAuthStart
  func disconnectMcpOAuth(id: String) async throws -> ServerMcpServer
  func removeMcpServer(id: String) async throws
  func listMcpTools(id: String) async throws -> [ServerMcpTool]
  func listNativeMcps() async throws -> ServerNativeMcpScan
  func importNativeMcps(identities: [String]) async throws -> ServerNativeMcpImportResult
  func removeNativeMcp(harnessId: String, serverName: String) async throws -> ServerRemoveNativeMcpResult
  func restoreNativeMcpRemoval(id: String) async throws -> ServerNativeMcpScan
  func setNativeMcpEnabled(harnessId: String, serverName: String, enabled: Bool) async throws -> ServerNativeMcpScan
  func listSkills() async throws -> ServerSkillsList
  func composerSkills(projectId: UUID?, sessionId: UUID?) async throws -> [ServerComposerSkill]
  func skillContent(directoryName: String) async throws -> String
  func updateSkill(directoryName: String, content: String) async throws -> ServerSkillsList
  func createSkill(name: String, description: String, content: String?) async throws -> ServerSkillsList
  func discoverRemoteSkills(source: String) async throws -> [ServerRemoteSkillCandidate]
  func importRemoteSkill(source: String, skillNames: [String]?) async throws -> ServerSkillsList
  func removeSkill(directoryName: String) async throws -> ServerSkillsList
  func listBots() async throws -> [ServerBot]
  func createBot(_ request: ServerCreateBotRequest) async throws -> ServerBot
  func updateBot(id: String, _ request: ServerUpdateBotRequest) async throws -> ServerBot
  func addBotProject(botId: String, projectId: String) async throws -> ServerBot
  func removeBotProject(botId: String, projectId: String) async throws -> ServerBot
  func deleteBot(id: String) async throws
  func botConversation(sessionId: UUID, before: Int?, limit: Int) async throws -> ServerBotConversationPage
  func listPluginCatalog(query: String?) async throws -> [ServerPluginCatalogEntry]
  func installCatalogPlugin(id: String, values: [String: ServerConfigFieldValue]) async throws -> ServerMcpServer
  func pluginCatalogEntry(id: String) async throws -> ServerPluginCatalogEntry
  func listPluginAccounts(serverId: String) async throws -> [ServerPluginAccount]
  func savePluginAccount(
    serverId: String,
    accountId: String?,
    draft: ServerPluginAccountDraft
  ) async throws -> ServerPluginAccount
  func removePluginAccount(serverId: String, accountId: String) async throws
  func startPluginAccountOAuth(
    serverId: String,
    request: ServerPluginAccountOAuthRequest
  ) async throws -> ServerPluginAccountOAuthStart
  func pluginAccountIngress(serverId: String, accountId: String) async throws -> [ServerPluginIngressURL]
  func listPluginEventSubscriptions() async throws -> [ServerPluginEventSubscription]
  func removePluginEventSubscription(id: String) async throws
  func issuePluginPaneToken(
    serverId: String,
    paneType: String,
    request: ServerPluginPaneTokenRequest
  ) async throws -> ServerPluginPaneTokenResponse
  func issuePluginAppViewToken(viewId: String) async throws -> ServerPluginPaneTokenResponse
  func navigationSnapshot() async throws -> ServerNavigationSnapshot
  func listProjects() async throws -> [ServerProject]
  func upsertProject(_ project: Project) async throws -> ServerProject
  func deleteProject(id: UUID) async throws
  func deleteProject(id: UUID, deletingFiles: Bool) async throws
  func listProjectGitBranches(projectId: UUID) async throws -> [ServerProjectGitBranch]
  func updateProjectWorktreeBase(
    id: UUID,
    worktreeBase: ProjectWorktreeBase?
  ) async throws -> ServerProject
  func updateProjectDefaultRunLocation(
    id: UUID,
    defaultRunLocation: ProjectRunLocation?
  ) async throws -> ServerProject
  func createScratchProject(id: UUID) async throws -> ServerProject
  func upsertWorkspacePane(_ pane: ServerWorkspacePane) async throws -> ServerWorkspacePane?
  func promoteWorkspacePaneToChat(
    _ pane: ServerWorkspacePane,
    session: ChatSession
  ) async throws -> ServerWorkspacePanePromotion?
  func closeWorkspacePane(workspaceId: UUID, paneId: UUID) async throws -> ServerWorkspacePane?
  func setWorkspaceArchived(id: UUID, isArchived: Bool) async throws
  func reorderWorkspace(id: UUID, position: String, expectedRevision: Int) async throws -> ServerWorkspace
  func moveWorkspacePane(workspaceId: UUID, paneId: UUID, position: String) async throws
  func renameWorkspace(id: UUID, name: String, hasCustomName: Bool) async throws
  func createWorktree(projectId: UUID, name: String?) async throws -> ServerWorktree
  func createWorktree(projectId: UUID, id: String?, name: String?) async throws -> ServerWorktree
  func listDirectory(path: String?, showHidden: Bool) async throws -> ServerFsListing
  func projectRecommendations(limit: Int) async throws -> [ServerProjectRecommendation]
  func firstRunStatus() async throws -> ServerFirstRunStatus
  func createDirectory(path: String) async throws -> String
  func createProjectFromGit(id: UUID, url: String, name: String?) async throws -> ServerProject
  func projectSetupSource(projectId: UUID) async throws -> ServerProjectSetupSource
  func sandboxVendors() async throws -> ServerSandboxVendors
  func sandboxProviders() async throws -> [ServerSandboxProvider]
  func createSandboxProvider(_ request: ServerSandboxProviderRequest) async throws -> ServerSandboxProvider
  func updateSandboxProvider(id: String, _ request: ServerSandboxProviderRequest) async throws -> ServerSandboxProvider
  func deleteSandboxProvider(id: String) async throws
  func sandboxProfiles() async throws -> [ServerSandboxProfile]
  func createSandboxProfile(_ request: ServerSandboxProfileRequest) async throws -> ServerSandboxProfile
  func updateSandboxProfile(id: String, _ request: ServerSandboxProfileRequest) async throws -> ServerSandboxProfile
  func deleteSandboxProfile(id: String) async throws
  func sandboxAvailability() async throws -> [ServerSandboxAvailability]
  func sandboxes() async throws -> [ServerSandbox]
  func destroySandbox(id: String) async throws
  func createSandbox(_ request: ServerSandboxRequest) async throws -> ServerSandbox
  func claimSandboxWorkspace(id: String, workspaceId: UUID) async throws -> ServerSandbox
  func readProjectEnvFiles(projectId: UUID, paths: [String]) async throws -> [ServerProjectEnvFileContent]
  func publishProjectRemote(projectId: UUID, url: String, initialize: Bool) async throws -> ServerProject
  func setUpProjectFromGit(_ request: ServerProjectSetupRequest) async throws -> ServerProject
  func cancelProjectSetup(id: UUID) async throws
  func projectCloneSettings() async throws -> ServerProjectCloneSettings
  func updateProjectCloneSettings(baseFolder: String?) async throws -> ServerProjectCloneSettings
  func gitAuthStatus(host: String) async throws -> ServerGitHostAuthStatus
  func startGitAuth(host: String) async throws -> ServerGitAuthFlow
  func gitAuthFlow(id: String) async throws -> ServerGitAuthFlow
  func cancelGitAuth(id: String) async throws
  func listSessions() async throws -> [ServerSession]
  func sessionUsageLimits(id: UUID) async throws -> ServerHarnessUsageLimits
  func sessionContext(id: UUID) async throws -> ServerSessionContext?
  func machineStats() async throws -> ServerMachineStats
  func openSession(
    _ session: ChatSession,
    project: Project?,
    transcriptLimit: Int
  ) async throws -> ServerSessionOpenResponse?
  func openSession(
    _ session: ChatSession,
    project: Project?,
    workspaceId: UUID?,
    transcriptLimit: Int
  ) async throws -> ServerSessionOpenResponse?
  func openSessionReturningData(
    _ session: ChatSession,
    project: Project?,
    workspaceId: UUID?,
    transcriptLimit: Int
  ) async throws -> ServerSessionOpenResult?
  func transcriptPage(id: UUID, before: String?, limit: Int) async throws -> ServerTranscriptPage
  func transcriptItemDetails(
    id: UUID,
    itemId: String,
    after: String?
  ) async throws -> ServerTranscriptItemDetails
  func transcriptBodyPage(
    id: UUID, itemId: String, key: String, field: String, position: Int
  ) async throws -> ServerTranscriptBodyPage
  func promptQueue(id: UUID) async throws -> [ServerPromptQueueItem]
  func upsertSession(_ session: ChatSession) async throws -> ServerSession
  func upsertSession(_ session: ChatSession, workspaceId: UUID?) async throws -> ServerSession
  func updateSession(_ session: ChatSession) async throws -> ServerSession
  func renameSession(_ session: ChatSession) async throws -> ServerSession
  func markSessionRead(id: UUID, throughSequence: Int) async throws -> ServerSession?
  func markSessionUnread(id: UUID) async throws -> ServerSession?
  func clearSessionPlanApproval(id: UUID) async throws
  func deleteSession(id: UUID) async throws
  func promptSession(id: UUID, text: String) async throws -> ServerPromptAccepted
  func promptSession(id: UUID, text: String, attachments: [ServerAttachmentRef]) async throws -> ServerPromptAccepted
  func promptSession(
    id: UUID, text: String, attachments: [ServerAttachmentRef], messageId: String?
  ) async throws -> ServerPromptAccepted
  func promptSession(
    id: UUID, text: String, attachments: [ServerAttachmentRef], messageId: String?,
    clientId: String?
  ) async throws -> ServerPromptAccepted
  func promptSession(
    id: UUID, text: String, attachments: [ServerAttachmentRef], messageId: String?,
    clientId: String?, delivery: ServerPromptDelivery
  ) async throws -> ServerPromptAccepted
  func promptSession(
    id: UUID, text: String, attachments: [ServerAttachmentRef], messageId: String?,
    clientId: String?, delivery: ServerPromptDelivery?, clientActionId: String
  ) async throws -> ServerPromptAccepted
  func promptSession(
    id: UUID, text: String, attribution: UserMessageAttribution
  ) async throws -> ServerPromptAccepted
  func uploadFile(name: String, mimeType: String, data: Data) async throws -> ServerFileMetadata
  func uploadFile(name: String, mimeType: String, fileURL: URL) async throws -> ServerFileMetadata
  func filePreview(id: String) async throws -> Data
  func filePreview(path: String, sessionId: UUID?) async throws -> Data
  func fileData(id: String) async throws -> Data
  func filePrefix(id: String, length: Int) async throws -> Data
  func toolIcon(_ request: ServerToolIconRequest) async throws -> Data
  func readDocument(path: String) async throws -> ServerFileDocument
  func saveDocument(path: String, content: String, version: String) async throws -> ServerFileDocument
  func createDocument(path: String, content: String) async throws -> ServerFileDocument
  func fileEntries(path: String, showHidden: Bool) async throws -> ServerFileListing
  func searchFileEntries(path: String, query: String) async throws -> ServerFileSearch
  func documentData(path: String) async throws -> Data
  func gitDiff(path: String, mode: ServerGitDiffMode, base: String?, revision: String?) async throws -> ServerGitDiff
  func gitRefs(path: String) async throws -> ServerGitRefs
  func gitPullRequest(path: String) async throws -> ServerGitPullRequest?
  func workspaceGit(workspaceId: UUID, includePullRequest: Bool) async throws -> ServerWorkspaceGit
  func workspaceMedia(workspaceId: UUID, before: String?, limit: Int) async throws -> ServerWorkspaceMediaPage
  func workspaceLinks(workspaceId: UUID, before: String?, limit: Int) async throws -> ServerWorkspaceLinkPage
  func linkPreview(url: URL) async throws -> ServerLinkPreview
  func linkPreviewImage(url: URL) async throws -> Data
  func fileData(sessionId: UUID, path: String) async throws -> Data
  func filePrefix(sessionId: UUID, path: String, length: Int) async throws -> Data
  func fileVersion(sessionId: UUID, path: String) async throws -> String?
  func updateQueuedPrompt(
    sessionId: UUID, queueItemId: String, text: String, attachments: [ServerAttachmentRef]?
  ) async throws -> ServerPromptQueueItem
  func reorderQueuedPrompts(
    sessionId: UUID,
    queueItemIds: [String]
  ) async throws -> [ServerPromptQueueItem]
  func deleteQueuedPrompt(sessionId: UUID, queueItemId: String) async throws
  func sendQueuedPromptNow(sessionId: UUID, queueItemId: String) async throws -> ServerPromptAccepted
  func cancelSession(id: UUID) async throws
  func setSessionMode(id: UUID, modeId: String) async throws
  func setSessionConfig(id: UUID, configId: String, value: String) async throws
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
  func cancelSessionAutoResume(id: UUID) async throws
  func answerSessionQuestion(
    id: UUID,
    questionId: String,
    outcome: String,
    answers: [String: QuestionAnswerEntry]?
  ) async throws
  func requestShutdown() async throws
  func applyServerUpdate(channel: ServerUpdateChannel) async throws -> ServerUpdateApplied
  func beginRestartDrain() async throws -> ServerRestartDrainState
  func restartDrainState() async throws -> ServerRestartDrainState
  func cancelRestartDrain() async throws
  func startUpdateRun(_ request: ServerUpdateRunRequest) async throws -> ServerUpdateRunStarted
  func updateRunState() async throws -> ServerUpdateRunState
  func cancelUpdateRun() async throws -> ServerUpdateRunState
  func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error>
  func shellEventStream() -> AsyncThrowingStream<ServerEventEnvelope, any Error>
  func shellEventStream(handledKinds: Set<String>) -> AsyncThrowingStream<ServerEventEnvelope, any Error>
  func latestShellEventCursor() async throws -> Int
  func shellEventStream(
    since: Int,
    handledKinds: Set<String>
  ) -> AsyncThrowingStream<ServerEventEnvelope, any Error>
  func sessionEventStream(id: UUID, since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error>
}
