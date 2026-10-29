import ACPKit
import CodevisorProtocol
import Foundation

public extension CodevisorServerClienting {
  func deleteProject(id: UUID, deletingFiles: Bool) async throws {
    guard !deletingFiles else { throw CodevisorServerClientError.invalidResponse }
    try await deleteProject(id: id)
  }

  func listProjectGitBranches(projectId: UUID) async throws -> [ServerProjectGitBranch] { [] }

  func updateProjectWorktreeBase(
    id: UUID,
    worktreeBase: ProjectWorktreeBase?
  ) async throws -> ServerProject {
    throw CodevisorServerClientError.invalidResponse
  }

  func updateProjectDefaultRunLocation(
    id: UUID,
    defaultRunLocation: ProjectRunLocation?
  ) async throws -> ServerProject {
    throw CodevisorServerClientError.invalidResponse
  }

  func cloudRegistration() async throws -> ServerCloudRegistration {
    ServerCloudRegistration(connected: false)
  }

  func connectCloud(serverURL _: URL, sessionToken _: String) async throws -> String {
    throw CodevisorServerClientError.invalidResponse
  }

  func connectCloud(
    serverURL _: URL,
    sessionToken _: String,
    managedBy _: String,
    machineName _: String?
  ) async throws -> String {
    throw CodevisorServerClientError.invalidResponse
  }

  func disconnectCloud() async throws {}

  func setCloudDirectPaths(_: Bool) async throws {}

  func updateInfo() async throws -> ServerUpdateInfo {
    try await updateInfo(refresh: false, channel: .stable)
  }

  func applyServerUpdate() async throws -> ServerUpdateApplied {
    try await applyServerUpdate(channel: .stable)
  }

  func mergeSyncDocument(
    namespace: String,
    entries: [ServerSyncEntry]
  ) async throws -> ServerSyncDocument {
    ServerSyncDocument(namespace: namespace, entries: entries)
  }
  func reconcileSkillsSync() async throws -> ServerSkillsSyncStatus {
    ServerSkillsSyncStatus(published: [], applied: [], removed: [], missingBlobs: [])
  }
  func reconcileMcpsSync() async throws -> ServerMcpSyncStatus {
    ServerMcpSyncStatus(published: [], applied: [], removed: [])
  }
  func publishAccountsSync() async throws {}
  func syncBlob(id: String) async throws -> Data {
    throw CodevisorServerClientError.invalidResponse
  }
  func putSyncBlob(id: String, bytes: Data) async throws {
    throw CodevisorServerClientError.invalidResponse
  }

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

  func openSession(
    _ session: ChatSession,
    project: Project?,
    transcriptLimit: Int
  ) async throws -> ServerSessionOpenResponse? { nil }

  func openSession(
    _ session: ChatSession,
    project: Project?,
    workspaceId: UUID?,
    transcriptLimit: Int
  ) async throws -> ServerSessionOpenResponse? {
    try await openSession(session, project: project, transcriptLimit: transcriptLimit)
  }

  func upsertSession(_ session: ChatSession, workspaceId: UUID?) async throws -> ServerSession {
    try await upsertSession(session)
  }

  func renameSession(_ session: ChatSession) async throws -> ServerSession {
    try await upsertSession(session)
  }

  func listPluginCatalog(query: String?) async throws -> [ServerPluginCatalogEntry] { [] }

  func installCatalogPlugin(id: String, values: [String: ServerConfigFieldValue]) async throws -> ServerMcpServer {
    throw CodevisorServerClientError.invalidResponse
  }

  func pluginCatalogEntry(id: String) async throws -> ServerPluginCatalogEntry {
    throw CodevisorServerClientError.invalidResponse
  }

  func listPluginAccounts(serverId: String) async throws -> [ServerPluginAccount] { [] }

  func savePluginAccount(
    serverId: String,
    accountId: String?,
    draft: ServerPluginAccountDraft
  ) async throws -> ServerPluginAccount {
    throw CodevisorServerClientError.invalidResponse
  }

  func removePluginAccount(serverId: String, accountId: String) async throws {
    throw CodevisorServerClientError.invalidResponse
  }

  func startPluginAccountOAuth(
    serverId: String,
    request: ServerPluginAccountOAuthRequest
  ) async throws -> ServerPluginAccountOAuthStart {
    throw CodevisorServerClientError.invalidResponse
  }

  func pluginAccountIngress(serverId: String, accountId: String) async throws -> [ServerPluginIngressURL] { [] }

  func listPluginEventSubscriptions() async throws -> [ServerPluginEventSubscription] { [] }

  func removePluginEventSubscription(id: String) async throws {
    throw CodevisorServerClientError.invalidResponse
  }

  func issuePluginPaneToken(
    serverId: String,
    paneType: String,
    request: ServerPluginPaneTokenRequest
  ) async throws -> ServerPluginPaneTokenResponse {
    throw CodevisorServerClientError.invalidResponse
  }

  func issuePluginAppViewToken(viewId: String) async throws -> ServerPluginPaneTokenResponse {
    throw CodevisorServerClientError.invalidResponse
  }

  func upsertWorkspacePane(_ pane: ServerWorkspacePane) async throws -> ServerWorkspacePane? { nil }
  func promoteWorkspacePaneToChat(
    _ pane: ServerWorkspacePane,
    session: ChatSession
  ) async throws -> ServerWorkspacePanePromotion? { nil }
  func closeWorkspacePane(workspaceId: UUID, paneId: UUID) async throws -> ServerWorkspacePane? { nil }

  func shellEventStream() -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
    eventStream(since: 0)
  }

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

  func rescanHarnesses() async throws -> [ServerHarness] {
    try await listHarnesses()
  }

  func listHarnessesWithLifecycle() async throws -> [ServerHarness] {
    try await listHarnesses()
  }

  func listAgentSessions(harnessId: String) async throws -> [SessionInfo] { [] }

  func installHarness(id: String, methodId: String?) async throws -> ServerHarnessOperationStarted {
    throw CodevisorServerClientError.invalidResponse
  }
  func updateHarness(id: String) async throws -> ServerHarnessOperationStarted {
    throw CodevisorServerClientError.invalidResponse
  }
  func bundledAppInfo(harnessId: String) async throws -> ServerHarnessBundledApp? { nil }
  func updateBundledApp(harnessId: String) async throws {
    throw CodevisorServerClientError.invalidResponse
  }
  func checkHarnessUpdates(harnessIds: [String]?) async throws -> [ServerHarness] { try await listHarnesses() }

  func refreshHarnessAuth() async throws -> [ServerHarness] { try await listHarnesses() }
  func settleHarnessAuth() async throws -> [ServerHarness] { try await listHarnesses() }
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
  func loginHarnessAccount(
    harnessId: String, accountId: String, methodId: String?, apiKey: String?
  ) async throws -> ServerHarnessAuthFlow {
    throw CodevisorServerClientError.invalidResponse
  }
  func answerHarnessLogin(
    harnessId: String, accountId: String, flowId: String, code: String
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
  func startMcpOAuth(id: String) async throws -> ServerMcpOAuthStart {
    throw CodevisorServerClientError.invalidResponse
  }
  func disconnectMcpOAuth(id: String) async throws -> ServerMcpServer {
    throw CodevisorServerClientError.invalidResponse
  }
  func removeMcpServer(id: String) async throws {}
  func listMcpTools(id: String) async throws -> [ServerMcpTool] { [] }

  func promptSession(id: UUID, text: String, attachments: [ServerAttachmentRef]) async throws -> ServerPromptAccepted {
    try await promptSession(id: id, text: text)
  }

  func promptSession(
    id: UUID, text: String, attachments: [ServerAttachmentRef], messageId: String?
  ) async throws -> ServerPromptAccepted {
    try await promptSession(id: id, text: text, attachments: attachments)
  }

  func promptSession(
    id: UUID, text: String, attachments: [ServerAttachmentRef], messageId: String?,
    clientId: String?
  ) async throws -> ServerPromptAccepted {
    try await promptSession(id: id, text: text, attachments: attachments, messageId: messageId)
  }

  func promptSession(
    id: UUID, text: String, attachments: [ServerAttachmentRef], messageId: String?,
    clientId: String?, delivery _: ServerPromptDelivery
  ) async throws -> ServerPromptAccepted {
    try await promptSession(
      id: id, text: text, attachments: attachments, messageId: messageId, clientId: clientId
    )
  }

  func uploadFile(name: String, mimeType: String, data: Data) async throws -> ServerFileMetadata {
    throw CodevisorServerClientError.invalidResponse
  }

  func uploadFile(name: String, mimeType: String, fileURL: URL) async throws -> ServerFileMetadata {
    throw CodevisorServerClientError.invalidResponse
  }

  func filePreview(id: String) async throws -> Data { throw CodevisorServerClientError.invalidResponse }
  func filePreview(path: String, sessionId: UUID?) async throws -> Data {
    throw CodevisorServerClientError.invalidResponse
  }

  func fileData(id: String) async throws -> Data {
    throw CodevisorServerClientError.invalidResponse
  }

  func filePrefix(id: String, length: Int) async throws -> Data {
    throw CodevisorServerClientError.invalidResponse
  }

  func toolIcon(_ request: ServerToolIconRequest) async throws -> Data {
    throw CodevisorServerClientError.invalidResponse
  }

  func fileData(sessionId: UUID, path: String) async throws -> Data {
    throw CodevisorServerClientError.invalidResponse
  }

  func filePrefix(sessionId: UUID, path: String, length: Int) async throws -> Data {
    throw CodevisorServerClientError.invalidResponse
  }

  func fileVersion(sessionId: UUID, path: String) async throws -> String? {
    nil
  }

  func transcriptPage(id: UUID, before: String?, limit: Int) async throws -> ServerTranscriptPage {
    throw CodevisorServerClientError.httpStatus(404, "")
  }

  func sessionUsageLimits(id: UUID) async throws -> ServerHarnessUsageLimits {
    throw CodevisorServerClientError.httpStatus(404, "")
  }

  func sessionContext(id: UUID) async throws -> ServerSessionContext? {
    nil
  }

  func machineStats() async throws -> ServerMachineStats {
    throw CodevisorServerClientError.httpStatus(404, "")
  }

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

  func cancelSessionAutoResume(id: UUID) async throws {}

  func answerSessionQuestion(
    id: UUID,
    questionId: String,
    outcome: String,
    answers: [String: QuestionAnswerEntry]?
  ) async throws {}

  func requestShutdown() async throws {}

  func applyServerUpdate(channel _: ServerUpdateChannel) async throws -> ServerUpdateApplied {
    ServerUpdateApplied(accepted: false, targetVersion: nil)
  }

  func updateQueuedPrompt(
    sessionId: UUID, queueItemId: String, text: String, attachments: [ServerAttachmentRef]?
  ) async throws -> ServerPromptQueueItem {
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

  func sendQueuedPromptNow(sessionId: UUID, queueItemId: String) async throws -> ServerPromptAccepted {
    ServerPromptAccepted(accepted: true, sessionId: sessionId.uuidString, queueItemId: queueItemId)
  }

  func setWorkspaceArchived(id: UUID, isArchived: Bool) async throws {}
  func reorderWorkspace(id: UUID, position: String, expectedRevision: Int) async throws -> ServerWorkspace {
    throw CodevisorServerClientError.httpStatus(405, "Workspace ordering is unavailable on this server.")
  }
  func renameWorkspace(id: UUID, name: String, hasCustomName: Bool) async throws {
    throw CodevisorServerClientError.invalidResponse
  }
  func moveWorkspacePane(workspaceId: UUID, paneId: UUID, position: String) async throws {
    throw CodevisorServerClientError.httpStatus(405, "Tab ordering is unavailable on this server.")
  }

  func createWorktree(projectId: UUID, name: String?) async throws -> ServerWorktree {
    throw CodevisorServerClientError.invalidResponse
  }

  func createWorktree(projectId: UUID, id: String?, name: String?) async throws -> ServerWorktree {
    try await createWorktree(projectId: projectId, name: name)
  }

  func listDirectory(path: String?, showHidden: Bool) async throws -> ServerFsListing {
    throw CodevisorServerClientError.invalidResponse
  }

  func createDirectory(path: String) async throws -> String {
    throw CodevisorServerClientError.invalidResponse
  }

  func createProjectFromGit(id: UUID, url: String, name: String?) async throws -> ServerProject {
    throw CodevisorServerClientError.invalidResponse
  }

  func createScratchProject(id: UUID) async throws -> ServerProject {
    throw CodevisorServerClientError.invalidResponse
  }
}

public extension CodevisorServerClienting {
  func reconcileHarnessesSync() async throws -> ServerHarnessSyncStatus {
    ServerHarnessSyncStatus(published: [], applied: [], removed: [], installing: [], blocked: [])
  }

  func reconcileCredentialsSync() async throws -> JSONValue {
    throw CodevisorServerClientError.invalidResponse
  }
}
extension CodevisorServerClienting {
  public func sharedHarnessAccount(
    harnessId: String, request: ServerSharedHarnessAccountRequest
  ) async throws -> ServerSharedHarnessAccountResponse {
    throw CodevisorServerClientError.httpStatus(501, "Update this machine to sync accounts.")
  }
}
