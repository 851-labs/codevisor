import type { SyncEntryRecord } from "@codevisor/sync"
import type {
  ArchivedWorktree,
  AttachmentKind,
  AttachmentRef,
  BrowserPreference,
  CreateProjectRequest,
  CreateSessionRequest,
  DataUpgradeProgress,
  EventEnvelope,
  EventKind,
  FileMetadata,
  Harness,
  Project,
  PromptQueueItem,
  SessionDetail,
  SessionSummary,
  TranscriptItemDetails,
  TranscriptPage,
  UpdateInfo,
  UpdateProjectRequest,
  UpdateSessionRequest,
  UpdateWorkspaceRequest,
  UpdateWorkspacePaneRequest,
  UpsertWorkspacePaneRequest,
  UpsertWorkspaceRequest,
  Workspace,
  WorkspacePane,
  WorkspaceSnapshot,
  Worktree
} from "@codevisor/api"
import Database from "better-sqlite3"
import { Context, Effect, Layer } from "effect"
import { createService } from "./create-service.js"
import { DatabaseError, attempt } from "./errors.js"
import type {
  FileStorageRecord,
  FileStorageState,
  HarnessAccountRecord,
  HarnessPendingUpdateRecord,
  HarnessUpdateStateRecord,
  McpServerRecord,
  NativeConfigBackupRecord,
  NativeMcpRemovalRecord,
  SaveHarnessAccountRequest,
  SaveMcpServerRecordRequest,
  SaveNativeMcpRemovalRequest,
  UpdateHarnessAccountAuthRequest
} from "./rows.js"

export interface CodevisorDatabaseConfig {
  readonly filename: string
  readonly serverId: string
  /// Synchronous by design: migrations use better-sqlite3 and report after
  /// every durable batch. The app-hosted server writes this to a sidecar file
  /// that remains readable while the HTTP server is still booting.
  readonly onDataUpgradeProgress?: (progress: DataUpgradeProgress) => void
  /// Test override for the grace between a released attention hold and the
  /// unread revision bump. Production uses ATTENTION_SETTLE_GRACE_MS.
  readonly attentionSettleGraceMs?: number
}

export interface CodevisorDatabaseService {
  readonly migrate: Effect.Effect<ReadonlyArray<string>, DatabaseError>
  readonly close: Effect.Effect<void>
  readonly createProject: (request: CreateProjectRequest) => Effect.Effect<Project, DatabaseError>
  readonly listProjects: Effect.Effect<ReadonlyArray<Project>, DatabaseError>
  readonly updateProject: (
    id: string,
    request: UpdateProjectRequest
  ) => Effect.Effect<Project, DatabaseError>
  readonly deleteProject: (id: string) => Effect.Effect<void, DatabaseError>
  /// Records the git remote discovered in a project's folder on this machine
  /// (null clears it). Deliberately not part of UpdateProjectRequest: the
  /// remote is observed, not chosen.
  readonly setProjectRepoUrl: (
    id: string,
    repoUrl: string | null
  ) => Effect.Effect<Project, DatabaseError>
  readonly createWorktree: (
    projectId: string,
    name: string,
    branch: string,
    id?: string
  ) => Effect.Effect<Worktree, DatabaseError>
  readonly listWorktrees: (
    projectId: string
  ) => Effect.Effect<ReadonlyArray<Worktree>, DatabaseError>
  readonly deleteWorktree: (id: string) => Effect.Effect<void, DatabaseError>
  /// Records a worktree whose files were snapshotted and removed. The matching
  /// `worktrees` row is deleted by the caller in the same flow, which is what
  /// releases the name back into the pool.
  readonly createArchivedWorktree: (
    record: ArchivedWorktree
  ) => Effect.Effect<ArchivedWorktree, DatabaseError>
  readonly findArchivedWorktree: (
    projectId: string,
    serverId: string,
    originalName: string
  ) => Effect.Effect<ArchivedWorktree | undefined, DatabaseError>
  readonly listArchivedWorktrees: (
    projectId: string
  ) => Effect.Effect<ReadonlyArray<ArchivedWorktree>, DatabaseError>
  readonly deleteArchivedWorktree: (id: string) => Effect.Effect<void, DatabaseError>
  readonly listWorkspaces: Effect.Effect<ReadonlyArray<Workspace>, DatabaseError>
  readonly upsertWorkspace: (
    request: UpsertWorkspaceRequest
  ) => Effect.Effect<Workspace, DatabaseError>
  /// Partial update. Flipping `isArchived` cascades to the workspace's
  /// sessions with provenance; see `archive_cascade_from`.
  readonly updateWorkspace: (
    id: string,
    request: UpdateWorkspaceRequest
  ) => Effect.Effect<Workspace, DatabaseError>
  readonly deleteWorkspace: (id: string) => Effect.Effect<void, DatabaseError>
  readonly getWorkspaceSnapshot: Effect.Effect<WorkspaceSnapshot, DatabaseError>
  readonly listWorkspacePanes: Effect.Effect<ReadonlyArray<WorkspacePane>, DatabaseError>
  readonly upsertWorkspacePane: (
    workspaceId: string,
    request: UpsertWorkspacePaneRequest
  ) => Effect.Effect<WorkspacePane, DatabaseError>
  readonly updateWorkspacePane: (
    workspaceId: string,
    paneId: string,
    request: UpdateWorkspacePaneRequest
  ) => Effect.Effect<WorkspacePane, DatabaseError>
  readonly deleteWorkspacePane: (
    workspaceId: string,
    paneId: string
  ) => Effect.Effect<WorkspacePane | undefined, DatabaseError>
  /// Atomically replaces one pane's renderer/resource and assigns the chat
  /// session to that workspace. It never manufactures a second pane id.
  readonly promoteWorkspacePaneToSession: (
    workspaceId: string,
    paneId: string,
    sessionId: string,
    title: string
  ) => Effect.Effect<WorkspacePane, DatabaseError>
  readonly setSessionWorkspace: (
    sessionId: string,
    workspaceId: string | null
  ) => Effect.Effect<void, DatabaseError>
  readonly createSession: (
    request: CreateSessionRequest
  ) => Effect.Effect<SessionSummary, DatabaseError>
  readonly listSessions: Effect.Effect<ReadonlyArray<SessionSummary>, DatabaseError>
  readonly getSessionSummary: (id: string) => Effect.Effect<SessionSummary, DatabaseError>
  readonly markSessionRead: (
    id: string,
    throughSequence: number
  ) => Effect.Effect<SessionSummary, DatabaseError>
  readonly markSessionUnread: (id: string) => Effect.Effect<SessionSummary, DatabaseError>
  readonly clearSessionPlanApproval: (id: string) => Effect.Effect<SessionSummary, DatabaseError>
  /// Settles a parked turn finish into an unread revision bump once its grace
  /// deadline has passed. Idempotent and re-validating: races with a turn
  /// that restarted (or a subagent that reappeared) are no-ops.
  readonly settleSessionAttention: (
    id: string
  ) => Effect.Effect<{ readonly settled: boolean; readonly nextDueAt?: string }, DatabaseError>
  readonly listPendingAttentionSettles: Effect.Effect<
    ReadonlyArray<{ readonly sessionId: string; readonly dueAt: string | null }>,
    DatabaseError
  >
  readonly getAttentionSettleDeadline: (
    id: string
  ) => Effect.Effect<string | undefined, DatabaseError>
  readonly getSessionConfigSelections: (
    id: string
  ) => Effect.Effect<Readonly<Record<string, string>>, DatabaseError>
  readonly getSessionDetail: (id: string) => Effect.Effect<SessionDetail, DatabaseError>
  readonly getTranscriptPage: (
    sessionId: string,
    before: number | undefined,
    limit: number
  ) => Effect.Effect<TranscriptPage, DatabaseError>
  readonly getTranscriptItemDetails: (
    sessionId: string,
    itemId: string,
    throughRevision?: number
  ) => Effect.Effect<TranscriptItemDetails | undefined, DatabaseError>
  readonly updateSession: (
    id: string,
    request: UpdateSessionRequest
  ) => Effect.Effect<SessionSummary, DatabaseError>
  readonly replaceSessionConfigSelections: (
    id: string,
    selections: Readonly<Record<string, string>>
  ) => Effect.Effect<void, DatabaseError>
  readonly updateSessionTitleFromHarness: (
    id: string,
    title: string
  ) => Effect.Effect<SessionSummary | undefined, DatabaseError>
  readonly archiveSession: (id: string) => Effect.Effect<SessionSummary, DatabaseError>
  readonly deleteSession: (id: string) => Effect.Effect<void, DatabaseError>
  readonly appendConversationItem: (
    sessionId: string,
    role: "user" | "assistant" | "system",
    messageId: string | undefined,
    text: string,
    isGenerating: boolean,
    attachments?: ReadonlyArray<AttachmentRef>
  ) => Effect.Effect<void, DatabaseError>
  readonly appendEvent: (
    kind: EventKind,
    subjectId: string,
    payload: unknown
  ) => Effect.Effect<EventEnvelope, DatabaseError>
  readonly latestEventCursor: Effect.Effect<number, DatabaseError>
  readonly listEvents: (since: number) => Effect.Effect<ReadonlyArray<EventEnvelope>, DatabaseError>
  readonly listSubjectEvents: (
    subjectId: string,
    since?: number
  ) => Effect.Effect<ReadonlyArray<EventEnvelope>, DatabaseError>
  readonly createPromptQueueItem: (
    sessionId: string,
    text: string,
    attachments?: ReadonlyArray<AttachmentRef>,
    id?: string
  ) => Effect.Effect<PromptQueueItem, DatabaseError>
  readonly createFile: (
    name: string,
    mimeType: string,
    kind: AttachmentKind,
    data: Buffer
  ) => Effect.Effect<FileMetadata, DatabaseError>
  readonly createDiskFile: (metadata: FileMetadata) => Effect.Effect<FileMetadata, DatabaseError>
  readonly getFileMetadata: (id: string) => Effect.Effect<FileMetadata | undefined, DatabaseError>
  readonly getFile: (
    id: string
  ) => Effect.Effect<{ metadata: FileMetadata; data: Buffer } | undefined, DatabaseError>
  readonly getFileStorage: (
    id: string
  ) => Effect.Effect<FileStorageRecord | undefined, DatabaseError>
  readonly listFileStorage: (
    state: FileStorageState,
    limit: number
  ) => Effect.Effect<ReadonlyArray<FileStorageRecord>, DatabaseError>
  readonly fileStorageCounts: Effect.Effect<
    Readonly<Record<FileStorageState, number>>,
    DatabaseError
  >
  readonly markFileStorageDual: (id: string) => Effect.Effect<void, DatabaseError>
  readonly markFileStorageDisk: (id: string) => Effect.Effect<void, DatabaseError>
  readonly listPromptQueue: (
    sessionId: string
  ) => Effect.Effect<ReadonlyArray<PromptQueueItem>, DatabaseError>
  readonly updatePromptQueueItem: (
    sessionId: string,
    queueItemId: string,
    text: string
  ) => Effect.Effect<PromptQueueItem, DatabaseError>
  readonly reorderPromptQueue: (
    sessionId: string,
    queueItemIds: ReadonlyArray<string>
  ) => Effect.Effect<ReadonlyArray<PromptQueueItem>, DatabaseError>
  readonly deletePromptQueueItem: (
    sessionId: string,
    queueItemId: string
  ) => Effect.Effect<void, DatabaseError>
  readonly claimPromptQueueItem: (
    sessionId: string
  ) => Effect.Effect<PromptQueueItem | undefined, DatabaseError>
  readonly completePromptQueueItem: (
    sessionId: string,
    queueItemId: string
  ) => Effect.Effect<void, DatabaseError>
  readonly listProcessingPromptQueue: (
    sessionId: string
  ) => Effect.Effect<ReadonlyArray<PromptQueueItem>, DatabaseError>
  readonly hasConversationMessage: (
    sessionId: string,
    messageId: string
  ) => Effect.Effect<boolean, DatabaseError>
  readonly hasTerminalAssistantAfterMessage: (
    sessionId: string,
    messageId: string
  ) => Effect.Effect<boolean, DatabaseError>
  /// Marks every still-streaming assistant chat item as failed except
  /// `excludeItemId`. Streaming rows are process-owned: whenever no live turn
  /// exists for them (server startup, crash recovery), they can never emit
  /// again and would otherwise render as an endless in-progress turn.
  readonly failStaleAssistantChatItems: (
    sessionId: string,
    stopDetail: string,
    excludeItemId?: string
  ) => Effect.Effect<number, DatabaseError>
  /// Session ids with at least one still-streaming assistant chat item whose
  /// session has appended no event since `quietSinceIso`. These are stuck-turn
  /// candidates: a genuinely live turn either streams events or is owned by an
  /// in-process prompt drain (which the caller must additionally check).
  readonly listQuietStreamingSessions: (
    quietSinceIso: string
  ) => Effect.Effect<ReadonlyArray<string>, DatabaseError>
  readonly getSessionActionResult: (
    sessionId: string,
    clientActionId: string
  ) => Effect.Effect<unknown | undefined, DatabaseError>
  readonly saveSessionActionResult: (
    sessionId: string,
    clientActionId: string,
    actionKind: string,
    response: unknown
  ) => Effect.Effect<void, DatabaseError>
  readonly setHarnessEnabled: (
    harnessId: string,
    enabled: boolean
  ) => Effect.Effect<void, DatabaseError>
  readonly applyHarnessSettings: (
    harnesses: ReadonlyArray<Harness>
  ) => Effect.Effect<ReadonlyArray<Harness>, DatabaseError>
  readonly listMcpServers: Effect.Effect<ReadonlyArray<McpServerRecord>, DatabaseError>
  readonly getMcpServer: (id: string) => Effect.Effect<McpServerRecord | undefined, DatabaseError>
  readonly saveMcpServer: (
    request: SaveMcpServerRecordRequest
  ) => Effect.Effect<McpServerRecord, DatabaseError>
  readonly deleteMcpServer: (id: string) => Effect.Effect<void, DatabaseError>
  readonly setProjectMcpEnabled: (
    projectId: string,
    mcpServerId: string,
    enabled: boolean
  ) => Effect.Effect<void, DatabaseError>
  readonly setSessionMcpEnabled: (
    sessionId: string,
    mcpServerId: string,
    enabled: boolean
  ) => Effect.Effect<void, DatabaseError>
  readonly resolveMcpServers: (
    projectId?: string,
    sessionId?: string
  ) => Effect.Effect<ReadonlyArray<McpServerRecord>, DatabaseError>
  readonly getNativeConfigBackup: (
    filePath: string
  ) => Effect.Effect<NativeConfigBackupRecord | undefined, DatabaseError>
  readonly saveNativeConfigBackup: (
    record: NativeConfigBackupRecord
  ) => Effect.Effect<void, DatabaseError>
  readonly saveNativeMcpRemoval: (
    request: SaveNativeMcpRemovalRequest
  ) => Effect.Effect<NativeMcpRemovalRecord, DatabaseError>
  readonly listNativeMcpRemovals: (
    includeRestored?: boolean
  ) => Effect.Effect<ReadonlyArray<NativeMcpRemovalRecord>, DatabaseError>
  readonly markNativeMcpRemovalRestored: (id: string) => Effect.Effect<void, DatabaseError>
  readonly listHarnessAccounts: (
    harnessId: string
  ) => Effect.Effect<ReadonlyArray<HarnessAccountRecord>, DatabaseError>
  readonly getHarnessAccount: (
    accountId: string
  ) => Effect.Effect<HarnessAccountRecord | undefined, DatabaseError>
  readonly saveHarnessAccount: (
    request: SaveHarnessAccountRequest
  ) => Effect.Effect<HarnessAccountRecord, DatabaseError>
  readonly updateHarnessAccountAuth: (
    accountId: string,
    request: UpdateHarnessAccountAuthRequest
  ) => Effect.Effect<HarnessAccountRecord, DatabaseError>
  readonly setActiveHarnessAccount: (
    harnessId: string,
    accountId: string
  ) => Effect.Effect<void, DatabaseError>
  readonly removeHarnessAccount: (accountId: string) => Effect.Effect<void, DatabaseError>
  readonly bindSessionHarnessAccount: (
    sessionId: string,
    accountId: string
  ) => Effect.Effect<SessionSummary, DatabaseError>
  /// Moves every session pinned to `fromAccountId` onto `toAccountId`.
  /// Claude selection applies this to every sibling so existing chats use the
  /// selected account on their next turn. Other harnesses use it to move
  /// sessions off unusable accounts. Returns the number of sessions moved.
  readonly rebindHarnessAccountSessions: (
    fromAccountId: string,
    toAccountId: string
  ) => Effect.Effect<number, DatabaseError>
  readonly issuePairingToken: Effect.Effect<string, DatabaseError>
  readonly verifyBearerToken: (token: string) => Effect.Effect<boolean, DatabaseError>
  /// A stable machine identity that survives --serverId defaults ("local") and
  /// renames: generated once on first access and persisted with the database.
  readonly getOrCreateInstanceId: Effect.Effect<string, DatabaseError>
  /// The machine's stable connection token: generated once, persisted, and
  /// returned unchanged across restarts and updates until rotated. This is
  /// what `codevisor token` prints and `codevisor setup` hands to clients.
  readonly getOrCreateConnectionToken: Effect.Effect<string, DatabaseError>
  /// Replaces the connection token with a fresh one and retires the old,
  /// forcing previously paired clients to re-pair.
  readonly rotateConnectionToken: Effect.Effect<string, DatabaseError>
  readonly getBrowserPreference: Effect.Effect<BrowserPreference | undefined, DatabaseError>
  readonly setBrowserPreference: (
    preference: BrowserPreference | undefined
  ) => Effect.Effect<void, DatabaseError>
  readonly getUpdateInfo: Effect.Effect<UpdateInfo, DatabaseError>
  readonly setUpdateInfo: (update: UpdateInfo) => Effect.Effect<UpdateInfo, DatabaseError>
  /// Persisted latest-version knowledge per harness (the periodic update
  /// check's output — survives restarts so clients see last-known state).
  readonly listHarnessUpdateStates: Effect.Effect<
    ReadonlyArray<HarnessUpdateStateRecord>,
    DatabaseError
  >
  readonly setHarnessUpdateState: (
    record: HarnessUpdateStateRecord
  ) => Effect.Effect<HarnessUpdateStateRecord, DatabaseError>
  /// Durable pending/running update per harness (the when-idle gate's truth).
  readonly listHarnessPendingUpdates: Effect.Effect<
    ReadonlyArray<HarnessPendingUpdateRecord>,
    DatabaseError
  >
  readonly setHarnessPendingUpdate: (
    record: HarnessPendingUpdateRecord
  ) => Effect.Effect<HarnessPendingUpdateRecord, DatabaseError>
  readonly clearHarnessPendingUpdate: (harnessId: string) => Effect.Effect<void, DatabaseError>
  /// Replicated config-plane documents (@codevisor/sync): this server's
  /// per-namespace LWW replica, merged rather than overwritten.
  readonly getSyncEntries: (
    namespace: string
  ) => Effect.Effect<ReadonlyArray<SyncEntryRecord>, DatabaseError>
  readonly mergeSyncEntries: (
    namespace: string,
    entries: ReadonlyArray<SyncEntryRecord>
  ) => Effect.Effect<
    {
      readonly merged: ReadonlyArray<SyncEntryRecord>
      readonly changed: ReadonlyArray<SyncEntryRecord>
    },
    DatabaseError
  >
}

export class CodevisorDatabase extends Context.Service<
  CodevisorDatabase,
  CodevisorDatabaseService
>()("@codevisor/db/CodevisorDatabase") {
  static readonly layer = (
    config: CodevisorDatabaseConfig
  ): Layer.Layer<CodevisorDatabase, DatabaseError> =>
    Layer.effect(
      CodevisorDatabase,
      Effect.map(makeDatabase(config), (service) => CodevisorDatabase.of(service))
    )
}

export const makeDatabase = (
  config: CodevisorDatabaseConfig
): Effect.Effect<CodevisorDatabaseService, DatabaseError> =>
  Effect.gen(function* () {
    const sqlite = yield* attempt("open", () => new Database(config.filename))
    sqlite.pragma("foreign_keys = ON")
    sqlite.pragma("journal_mode = WAL")
    const service = createService(sqlite, config)
    yield* service.migrate
    return service
  })
