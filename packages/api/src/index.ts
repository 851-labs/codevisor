import { Schema } from "effect"
import { QuestionAnswerEntry } from "./session-updates.js"

export * from "./session-updates.js"

export const isoTimestamp = (): string => new Date().toISOString()

export const ServerKind = Schema.Literals(["local", "remote"])
export type ServerKind = typeof ServerKind.Type

export const SessionOrigin = Schema.Literals(["herdman", "imported"])
export type SessionOrigin = typeof SessionOrigin.Type

export const HarnessReadiness = Schema.Struct({
  state: Schema.Literals(["ready", "unavailable"]),
  detail: Schema.optional(Schema.String)
})
export type HarnessReadiness = typeof HarnessReadiness.Type

export const Harness = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  symbolName: Schema.String,
  source: Schema.String,
  launchKind: Schema.Literals(["executable", "npx", "uvx", "unknown"]),
  enabled: Schema.Boolean,
  readiness: HarnessReadiness,
  /// Copyable shell command that installs the harness CLI; present only for
  /// harnesses with a well-known installer.
  installHint: Schema.optional(Schema.String)
})
export type Harness = typeof Harness.Type

export const UpdateHarnessRequest = Schema.Struct({
  enabled: Schema.Boolean
})
export type UpdateHarnessRequest = typeof UpdateHarnessRequest.Type

/// A session from a harness's own on-disk store (run before/outside
/// HerdMan) — the source for onboarding's workspace suggestions and
/// "import existing chats".
export const AgentSessionSummary = Schema.Struct({
  sessionId: Schema.String,
  cwd: Schema.String,
  title: Schema.optional(Schema.String),
  updatedAt: Schema.optional(Schema.String)
})
export type AgentSessionSummary = typeof AgentSessionSummary.Type

/// HerdMan's harness-independent mode vocabulary. Providers map their native
/// permission/approval modes onto these ids so the client can render one
/// consistent picker; modes without a mapping stay native-only.
export const CanonicalModeId = Schema.Literals([
  "readOnly",
  "ask",
  "autoEdit",
  "fullAccess",
  "plan"
])
export type CanonicalModeId = typeof CanonicalModeId.Type

export const SessionMode = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  description: Schema.optional(Schema.String),
  canonicalId: Schema.optional(CanonicalModeId)
})
export type SessionMode = typeof SessionMode.Type

export const SessionModeState = Schema.Struct({
  currentModeId: Schema.String,
  availableModes: Schema.Array(SessionMode)
})
export type SessionModeState = typeof SessionModeState.Type

export const SessionConfigSelectOption = Schema.Struct({
  value: Schema.String,
  name: Schema.String,
  description: Schema.optional(Schema.String)
})
export type SessionConfigSelectOption = typeof SessionConfigSelectOption.Type

export const SessionConfigSelectGroup = Schema.Struct({
  group: Schema.String,
  name: Schema.String,
  options: Schema.Array(SessionConfigSelectOption)
})
export type SessionConfigSelectGroup = typeof SessionConfigSelectGroup.Type

export const SessionConfigOption = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  description: Schema.optional(Schema.String),
  category: Schema.optional(Schema.String),
  currentValue: Schema.String,
  options: Schema.Union([
    Schema.Array(SessionConfigSelectOption),
    Schema.Array(SessionConfigSelectGroup)
  ])
})
export type SessionConfigOption = typeof SessionConfigOption.Type

/// Lifecycle of a session goal, mirroring codex's thread-goal statuses.
/// `active` goals auto-continue turns agent-side until done or limited.
export const GoalStatus = Schema.Literals([
  "active",
  "paused",
  "blocked",
  "usageLimited",
  "budgetLimited",
  "complete"
])
export type GoalStatus = typeof GoalStatus.Type

/// A persistent per-session objective (codex "goal mode"). Snapshots are
/// idempotent full state: consumers replace, never accumulate.
export const SessionGoal = Schema.Struct({
  objective: Schema.String,
  status: GoalStatus,
  tokenBudget: Schema.NullOr(Schema.Number),
  tokensUsed: Schema.Number,
  timeUsedSeconds: Schema.Number,
  createdAt: Schema.String,
  updatedAt: Schema.String
})
export type SessionGoal = typeof SessionGoal.Type

export const HarnessCapability = Schema.Struct({
  harness: Harness,
  modes: Schema.optional(SessionModeState),
  configOptions: Schema.Array(SessionConfigOption),
  supportsGoals: Schema.optional(Schema.Boolean)
})
export type HarnessCapability = typeof HarnessCapability.Type

export const ServerCapabilities = Schema.Struct({
  harnesses: Schema.Array(HarnessCapability)
})
export type ServerCapabilities = typeof ServerCapabilities.Type

export const ProjectLocation = Schema.Struct({
  id: Schema.String,
  projectId: Schema.String,
  serverId: Schema.String,
  folderPath: Schema.String,
  createdAt: Schema.String,
  isGitRepository: Schema.optional(Schema.Boolean)
})
export type ProjectLocation = typeof ProjectLocation.Type

export const Project = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  isArchived: Schema.Boolean,
  symbolName: Schema.String,
  origin: SessionOrigin,
  createdAt: Schema.String,
  locations: Schema.Array(ProjectLocation)
})
export type Project = typeof Project.Type

export const CreateProjectRequest = Schema.Struct({
  id: Schema.optional(Schema.String),
  folderPath: Schema.String,
  name: Schema.optional(Schema.String),
  isArchived: Schema.optional(Schema.Boolean),
  symbolName: Schema.optional(Schema.String),
  origin: Schema.optional(SessionOrigin),
  createdAt: Schema.optional(Schema.String)
})
export type CreateProjectRequest = typeof CreateProjectRequest.Type

export const UpdateProjectRequest = Schema.Struct({
  name: Schema.optional(Schema.String),
  isArchived: Schema.optional(Schema.Boolean),
  symbolName: Schema.optional(Schema.String)
})
export type UpdateProjectRequest = typeof UpdateProjectRequest.Type

export const Worktree = Schema.Struct({
  id: Schema.String,
  projectId: Schema.String,
  serverId: Schema.String,
  name: Schema.String,
  branch: Schema.String,
  path: Schema.String,
  createdAt: Schema.String
})
export type Worktree = typeof Worktree.Type

export const CreateWorktreeRequest = Schema.Struct({
  /// Client-supplied worktree id so callers can follow `worktree.setup` events
  /// (subjectId = worktree id) while the create request is still in flight.
  id: Schema.optional(Schema.String),
  name: Schema.optional(Schema.String)
})
export type CreateWorktreeRequest = typeof CreateWorktreeRequest.Type

export const WorktreeSetupState = Schema.Literals(["started", "log", "completed", "failed"])
export type WorktreeSetupState = typeof WorktreeSetupState.Type

/** Progress payload carried on `worktree.setup` envelopes while the server
 *  materializes a worktree (`git worktree add` plus any checkout hooks).
 *  `log` updates stream one output line each; `completed`/`failed` carry the
 *  total `durationMs`, and `failed` carries the error `message`. */
export const WorktreeSetupUpdate = Schema.Struct({
  state: WorktreeSetupState,
  worktreeId: Schema.String,
  projectId: Schema.String,
  name: Schema.String,
  branch: Schema.String,
  stream: Schema.optional(Schema.Literals(["stdout", "stderr"])),
  line: Schema.optional(Schema.String),
  message: Schema.optional(Schema.String),
  durationMs: Schema.optional(Schema.Number)
})
export type WorktreeSetupUpdate = typeof WorktreeSetupUpdate.Type

export const SessionUsage = Schema.Struct({
  used: Schema.optional(Schema.Number),
  size: Schema.optional(Schema.Number),
  costAmount: Schema.optional(Schema.Number),
  costCurrency: Schema.optional(Schema.String)
})
export type SessionUsage = typeof SessionUsage.Type

export const SessionSummary = Schema.Struct({
  id: Schema.String,
  projectId: Schema.String,
  serverId: Schema.String,
  harnessId: Schema.String,
  agentSessionId: Schema.optional(Schema.String),
  title: Schema.String,
  origin: SessionOrigin,
  isArchived: Schema.Boolean,
  worktreeName: Schema.optional(Schema.String),
  cwd: Schema.optional(Schema.String),
  createdAt: Schema.String,
  updatedAt: Schema.optional(Schema.String),
  usage: Schema.optional(SessionUsage)
})
export type SessionSummary = typeof SessionSummary.Type

export const ConversationRole = Schema.Literals(["user", "assistant", "system"])
export type ConversationRole = typeof ConversationRole.Type

export const AttachmentKind = Schema.Literals(["image", "file"])
export type AttachmentKind = typeof AttachmentKind.Type

/// A reference to an uploaded file (`POST /v1/files`) carried on a prompt and
/// persisted with the user message; bytes are fetched via `GET /v1/files/:id`.
export const AttachmentRef = Schema.Struct({
  fileId: Schema.String,
  name: Schema.String,
  mimeType: Schema.String,
  sizeBytes: Schema.Number,
  kind: AttachmentKind
})
export type AttachmentRef = typeof AttachmentRef.Type

export const FileMetadata = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  mimeType: Schema.String,
  sizeBytes: Schema.Number,
  sha256: Schema.String,
  kind: AttachmentKind,
  createdAt: Schema.String
})
export type FileMetadata = typeof FileMetadata.Type

export const ConversationItem = Schema.Struct({
  id: Schema.String,
  role: ConversationRole,
  messageId: Schema.optional(Schema.String),
  text: Schema.String,
  createdAt: Schema.String,
  isGenerating: Schema.Boolean,
  attachments: Schema.optional(Schema.Array(AttachmentRef))
})
export type ConversationItem = typeof ConversationItem.Type

export const PromptQueueItem = Schema.Struct({
  id: Schema.String,
  sessionId: Schema.String,
  text: Schema.String,
  createdAt: Schema.String,
  updatedAt: Schema.String,
  attachments: Schema.optional(Schema.Array(AttachmentRef))
})
export type PromptQueueItem = typeof PromptQueueItem.Type

export const SessionDetail = Schema.Struct({
  session: SessionSummary,
  conversation: Schema.Array(ConversationItem),
  promptQueue: Schema.Array(PromptQueueItem),
  eventCursor: Schema.Number
})
export type SessionDetail = typeof SessionDetail.Type

export const CreateSessionRequest = Schema.Struct({
  id: Schema.optional(Schema.String),
  projectId: Schema.String,
  harnessId: Schema.String,
  agentSessionId: Schema.optional(Schema.String),
  title: Schema.optional(Schema.String),
  origin: Schema.optional(SessionOrigin),
  isArchived: Schema.optional(Schema.Boolean),
  worktreeName: Schema.optional(Schema.String),
  createdAt: Schema.optional(Schema.String),
  updatedAt: Schema.optional(Schema.String)
})
export type CreateSessionRequest = typeof CreateSessionRequest.Type

export const UpdateSessionRequest = Schema.Struct({
  agentSessionId: Schema.optional(Schema.String),
  isArchived: Schema.optional(Schema.Boolean),
  title: Schema.optional(Schema.String),
  /// Explicit activity stamp, sent only when a turn finishes; plain metadata
  /// updates must omit it so recency ordering ignores opens/renames.
  updatedAt: Schema.optional(Schema.String)
})
export type UpdateSessionRequest = typeof UpdateSessionRequest.Type

export const PromptRequest = Schema.Struct({
  text: Schema.String,
  clientActionId: Schema.optional(Schema.String),
  attachments: Schema.optional(Schema.Array(AttachmentRef))
})
export type PromptRequest = typeof PromptRequest.Type

export const PromptAcceptedResponse = Schema.Struct({
  accepted: Schema.Boolean,
  sessionId: Schema.String,
  queueItemId: Schema.optional(Schema.String)
})
export type PromptAcceptedResponse = typeof PromptAcceptedResponse.Type

export const UpdateQueuedPromptRequest = Schema.Struct({
  text: Schema.String
})
export type UpdateQueuedPromptRequest = typeof UpdateQueuedPromptRequest.Type

export const CancelRequest = Schema.Struct({
  clientActionId: Schema.optional(Schema.String)
})
export type CancelRequest = typeof CancelRequest.Type

export const SetModeRequest = Schema.Struct({
  modeId: Schema.String,
  clientActionId: Schema.optional(Schema.String)
})
export type SetModeRequest = typeof SetModeRequest.Type

export const SetConfigRequest = Schema.Struct({
  configId: Schema.String,
  value: Schema.String,
  clientActionId: Schema.optional(Schema.String)
})
export type SetConfigRequest = typeof SetConfigRequest.Type

/// Partial goal update mirroring codex `thread/goal/set` semantics: omitted
/// fields keep their current value. `tokenBudget` is a double-option — omit
/// to keep, `null` to clear the budget, a positive number to set it.
export const SetGoalRequest = Schema.Struct({
  objective: Schema.optional(Schema.String),
  status: Schema.optional(GoalStatus),
  tokenBudget: Schema.optional(Schema.NullOr(Schema.Number)),
  clientActionId: Schema.optional(Schema.String)
})
export type SetGoalRequest = typeof SetGoalRequest.Type

/// Answers (or dismisses) a blocking agent question. `answers` is keyed by
/// the per-question id from the QuestionPayload; omitted for `cancelled`.
export const SetQuestionAnswerRequest = Schema.Struct({
  outcome: Schema.Literals(["answered", "cancelled"]),
  answers: Schema.optional(Schema.Record(Schema.String, QuestionAnswerEntry)),
  clientActionId: Schema.optional(Schema.String)
})
export type SetQuestionAnswerRequest = typeof SetQuestionAnswerRequest.Type

export const HealthResponse = Schema.Struct({
  ok: Schema.Boolean,
  version: Schema.String,
  database: Schema.Literals(["ready", "migrating"])
})
export type HealthResponse = typeof HealthResponse.Type

export const ServerInfo = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  kind: ServerKind,
  version: Schema.String,
  platform: Schema.String,
  bindHost: Schema.String
})
export type ServerInfo = typeof ServerInfo.Type

export const UpdateInfo = Schema.Struct({
  currentVersion: Schema.String,
  latestVersion: Schema.String,
  updateAvailable: Schema.Boolean,
  channel: Schema.String,
  checkedAt: Schema.optional(Schema.String),
  migrationState: Schema.Literals(["idle", "running", "failed"])
})
export type UpdateInfo = typeof UpdateInfo.Type

export const PairingTokenResponse = Schema.Struct({
  token: Schema.String,
  createdAt: Schema.String
})
export type PairingTokenResponse = typeof PairingTokenResponse.Type

export const EventKind = Schema.Literals([
  "project.created",
  "project.updated",
  "project.deleted",
  "worktree.created",
  "worktree.setup",
  "session.created",
  "session.updated",
  "session.archived",
  "session.deleted",
  "session.output",
  "session.queue.updated",
  "session.error",
  "terminal.output",
  "terminal.exit",
  "update.changed"
])
export type EventKind = typeof EventKind.Type

export const EventEnvelope = Schema.Struct({
  id: Schema.Number,
  serverId: Schema.String,
  kind: EventKind,
  subjectId: Schema.String,
  createdAt: Schema.String,
  payload: Schema.Unknown
})
export type EventEnvelope = typeof EventEnvelope.Type

export const TerminalCreateRequest = Schema.Struct({
  sessionId: Schema.String,
  cwd: Schema.String,
  cols: Schema.Number,
  rows: Schema.Number,
  shell: Schema.optional(Schema.String),
  /** Attach to an existing (possibly exited) terminal under `sessionId`
   *  without ever spawning a shell — used for agent-owned background-task
   *  terminals, where the process lifecycle belongs to the agent runtime.
   *  Fails when nothing is registered yet; clients retry. */
  attachOnly: Schema.optional(Schema.Boolean)
})
export type TerminalCreateRequest = typeof TerminalCreateRequest.Type

export const TerminalCreateResponse = Schema.Struct({
  terminalId: Schema.String,
  websocketPath: Schema.String,
  nextOutputSeq: Schema.Number
})
export type TerminalCreateResponse = typeof TerminalCreateResponse.Type

const TerminalClientFrameBase = {
  clientId: Schema.String,
  clientSeq: Schema.Number
} as const

export const TerminalClientFrame = Schema.Union([
  Schema.Struct({ ...TerminalClientFrameBase, type: Schema.Literal("input"), data: Schema.String }),
  Schema.Struct({
    ...TerminalClientFrameBase,
    type: Schema.Literal("resize"),
    cols: Schema.Number,
    rows: Schema.Number
  }),
  Schema.Struct({ ...TerminalClientFrameBase, type: Schema.Literal("close") })
])
export type TerminalClientFrame = typeof TerminalClientFrame.Type

export const TerminalServerFrame = Schema.Union([
  Schema.Struct({ type: Schema.Literal("output"), seq: Schema.Number, data: Schema.String }),
  Schema.Struct({
    type: Schema.Literal("exit"),
    seq: Schema.Number,
    exitCode: Schema.optional(Schema.Number)
  }),
  Schema.Struct({ type: Schema.Literal("error"), seq: Schema.Number, message: Schema.String })
])
export type TerminalServerFrame = typeof TerminalServerFrame.Type

export const HerdManOpenApi = Schema.Struct({
  openapi: Schema.Literal("3.1.0"),
  info: Schema.Struct({
    title: Schema.String,
    version: Schema.String
  }),
  paths: Schema.Record(Schema.String, Schema.Unknown)
})
export type HerdManOpenApi = typeof HerdManOpenApi.Type

export const endpoints = [
  "GET /v1/health",
  "GET /v1/info",
  "GET /v1/update",
  "POST /v1/update/apply",
  "POST /v1/shutdown",
  "GET /v1/capabilities",
  "POST /v1/auth/pairing-token",
  "GET /v1/projects",
  "POST /v1/projects",
  "PATCH /v1/projects/:id",
  "DELETE /v1/projects/:id",
  "GET /v1/projects/:id/worktrees",
  "POST /v1/projects/:id/worktrees",
  "GET /v1/harnesses",
  "PATCH /v1/harnesses/:id",
  "GET /v1/sessions",
  "POST /v1/sessions",
  "GET /v1/sessions/:id",
  "PATCH /v1/sessions/:id",
  "DELETE /v1/sessions/:id",
  "GET /v1/sessions/:id/queue",
  "PATCH /v1/sessions/:id/queue/:queueId",
  "DELETE /v1/sessions/:id/queue/:queueId",
  "POST /v1/sessions/:id/prompt",
  "POST /v1/sessions/:id/cancel",
  "POST /v1/sessions/:id/mode",
  "POST /v1/sessions/:id/config",
  "POST /v1/sessions/:id/goal",
  "DELETE /v1/sessions/:id/goal",
  "POST /v1/sessions/:id/questions/:questionId/answer",
  "POST /v1/files",
  "GET /v1/files/:id",
  "GET /v1/events",
  "GET /v1/events/socket",
  "POST /v1/terminals",
  "GET /v1/terminals/:id/socket"
] as const

export const makeOpenApiDocument = (version: string): HerdManOpenApi => ({
  openapi: "3.1.0",
  info: {
    title: "HerdMan Server API",
    version
  },
  paths: Object.fromEntries(endpoints.map((endpoint) => [endpoint, { "x-herdman-endpoint": true }]))
})

export const decode =
  <S extends Schema.ConstraintDecoder<unknown>>(schema: S) =>
  (input: unknown): S["Type"] =>
    Schema.decodeUnknownSync(schema)(input)

export const encode =
  <S extends Schema.ConstraintEncoder<unknown>>(schema: S) =>
  (input: S["Type"]): S["Encoded"] =>
    Schema.encodeSync(schema)(input)
