import { Schema } from "effect"
import { BackgroundTask, QuestionAnswerEntry, QuestionPayload } from "./session-updates.js"

export * from "./session-updates.js"

export const isoTimestamp = (): string => new Date().toISOString()

export const ServerKind = Schema.Literals(["local", "remote"])
export type ServerKind = typeof ServerKind.Type

export const SessionOrigin = Schema.Union([
  Schema.Literal("codevisor"),
  Schema.Literal("imported"),
  // Decode payloads from pre-rename servers without leaking the former value
  // into the current application model.
  Schema.Literal("herdman").transform("codevisor")
])
export type SessionOrigin = typeof SessionOrigin.Type

export const HarnessReadiness = Schema.Struct({
  state: Schema.Literals(["ready", "unavailable"]),
  detail: Schema.optional(Schema.String),
  /// Resolved binary location and version for ready harnesses. Structured on
  /// purpose: clients show them, and future config-sync diffs "what's
  /// installed where" across machines.
  path: Schema.optional(Schema.String),
  version: Schema.optional(Schema.String)
})
export type HarnessReadiness = typeof HarnessReadiness.Type

export const HarnessAuthState = Schema.Literals([
  "checking",
  "authenticated",
  "unauthenticated",
  "expired",
  "notRequired",
  "unavailable",
  "error"
])
export type HarnessAuthState = typeof HarnessAuthState.Type

export const HarnessAuthMethod = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  description: Schema.optional(Schema.String),
  kind: Schema.Literals(["browser", "deviceCode", "terminal", "agent", "apiKey"])
})
export type HarnessAuthMethod = typeof HarnessAuthMethod.Type

export const HarnessAccount = Schema.Struct({
  id: Schema.String,
  harnessId: Schema.String,
  profileKind: Schema.Literals(["default", "managed"]),
  label: Schema.String,
  email: Schema.optional(Schema.String),
  organizationId: Schema.optional(Schema.String),
  authMethod: Schema.optional(Schema.String),
  authState: HarnessAuthState,
  isActive: Schema.Boolean,
  canLogin: Schema.Boolean,
  canLogout: Schema.Boolean,
  lastCheckedAt: Schema.optional(Schema.String),
  detail: Schema.optional(Schema.String)
})
export type HarnessAccount = typeof HarnessAccount.Type

export const HarnessAuth = Schema.Struct({
  state: HarnessAuthState,
  activeAccountId: Schema.optional(Schema.String),
  accounts: Schema.Array(HarnessAccount),
  loginMethods: Schema.Array(HarnessAuthMethod),
  supportsMultipleAccounts: Schema.Boolean,
  detail: Schema.optional(Schema.String)
})
export type HarnessAuth = typeof HarnessAuth.Type

export const Harness = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  symbolName: Schema.String,
  source: Schema.String,
  launchKind: Schema.Literals(["executable", "npx", "uvx", "unknown"]),
  enabled: Schema.Boolean,
  /// Persisted user preference. `enabled` is the effective value after
  /// installation and authentication gates have been applied. Optional for
  /// compatibility with older Codevisor servers and cached client models.
  desiredEnabled: Schema.optional(Schema.Boolean),
  readiness: HarnessReadiness,
  /// Harness-owned authentication state. Optional while talking to servers
  /// that predate account management.
  auth: Schema.optional(HarnessAuth),
  /// Copyable shell command that installs the harness CLI; present only for
  /// harnesses with a well-known installer.
  installHint: Schema.optional(Schema.String)
})
export type Harness = typeof Harness.Type

export const CreateHarnessAccountRequest = Schema.Struct({
  label: Schema.optional(Schema.String)
})
export type CreateHarnessAccountRequest = typeof CreateHarnessAccountRequest.Type

export const UpdateHarnessAccountRequest = Schema.Struct({
  label: Schema.optional(Schema.String)
})
export type UpdateHarnessAccountRequest = typeof UpdateHarnessAccountRequest.Type

export const StartHarnessLoginRequest = Schema.Struct({
  methodId: Schema.optional(Schema.String),
  apiKey: Schema.optional(Schema.String)
})
export type StartHarnessLoginRequest = typeof StartHarnessLoginRequest.Type

export const HarnessAuthFlow = Schema.Union([
  Schema.Struct({
    id: Schema.String,
    accountId: Schema.String,
    kind: Schema.Literal("browser"),
    url: Schema.String
  }),
  Schema.Struct({
    id: Schema.String,
    accountId: Schema.String,
    kind: Schema.Literal("deviceCode"),
    verificationUrl: Schema.String,
    userCode: Schema.String
  }),
  Schema.Struct({
    id: Schema.String,
    accountId: Schema.String,
    kind: Schema.Literal("terminal"),
    terminalId: Schema.String,
    terminalKey: Schema.optional(Schema.String)
  }),
  Schema.Struct({
    id: Schema.String,
    accountId: Schema.String,
    kind: Schema.Literal("complete")
  })
])
export type HarnessAuthFlow = typeof HarnessAuthFlow.Type

export const PiAuthMethod = Schema.Literals(["api_key", "oauth"])
export type PiAuthMethod = typeof PiAuthMethod.Type

export const PiAuthProvider = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  methods: Schema.Array(PiAuthMethod),
  credentialType: Schema.optional(PiAuthMethod)
})
export type PiAuthProvider = typeof PiAuthProvider.Type

export const PiAuthPromptOption = Schema.Struct({
  id: Schema.String,
  label: Schema.String,
  description: Schema.optional(Schema.String)
})
export type PiAuthPromptOption = typeof PiAuthPromptOption.Type

export const PiAuthPrompt = Schema.Struct({
  id: Schema.String,
  type: Schema.Literals(["text", "secret", "select", "manual_code"]),
  message: Schema.String,
  placeholder: Schema.optional(Schema.String),
  options: Schema.Array(PiAuthPromptOption)
})
export type PiAuthPrompt = typeof PiAuthPrompt.Type

export const PiAuthEvent = Schema.Struct({
  type: Schema.Literals(["info", "auth_url", "device_code", "progress"]),
  message: Schema.optional(Schema.String),
  url: Schema.optional(Schema.String),
  userCode: Schema.optional(Schema.String),
  verificationUrl: Schema.optional(Schema.String)
})
export type PiAuthEvent = typeof PiAuthEvent.Type

export const PiAuthProviderFlow = Schema.Struct({
  id: Schema.String,
  providerId: Schema.String,
  state: Schema.Literals(["running", "waiting", "complete", "error"]),
  prompt: Schema.optional(PiAuthPrompt),
  event: Schema.optional(PiAuthEvent),
  error: Schema.optional(Schema.String)
})
export type PiAuthProviderFlow = typeof PiAuthProviderFlow.Type

export const StartPiAuthRequest = Schema.Struct({ method: PiAuthMethod })
export type StartPiAuthRequest = typeof StartPiAuthRequest.Type

export const AnswerPiAuthRequest = Schema.Struct({ value: Schema.String })
export type AnswerPiAuthRequest = typeof AnswerPiAuthRequest.Type

export const OpenCodeAuthPromptCondition = Schema.Struct({
  key: Schema.String,
  op: Schema.Literals(["eq", "neq"]),
  value: Schema.String
})
export type OpenCodeAuthPromptCondition = typeof OpenCodeAuthPromptCondition.Type

export const OpenCodeAuthPromptOption = Schema.Struct({
  value: Schema.String,
  label: Schema.String,
  hint: Schema.optional(Schema.String)
})
export type OpenCodeAuthPromptOption = typeof OpenCodeAuthPromptOption.Type

export const OpenCodeAuthPrompt = Schema.Struct({
  type: Schema.Literals(["text", "select"]),
  key: Schema.String,
  message: Schema.String,
  placeholder: Schema.optional(Schema.String),
  options: Schema.Array(OpenCodeAuthPromptOption),
  when: Schema.optional(OpenCodeAuthPromptCondition)
})
export type OpenCodeAuthPrompt = typeof OpenCodeAuthPrompt.Type

export const OpenCodeAuthMethod = Schema.Struct({
  id: Schema.String,
  type: Schema.Literals(["api", "oauth"]),
  label: Schema.String,
  prompts: Schema.Array(OpenCodeAuthPrompt)
})
export type OpenCodeAuthMethod = typeof OpenCodeAuthMethod.Type

export const OpenCodeAuthProvider = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  methods: Schema.Array(OpenCodeAuthMethod),
  credentialType: Schema.optional(Schema.Literals(["api", "oauth", "wellknown"]))
})
export type OpenCodeAuthProvider = typeof OpenCodeAuthProvider.Type

export const OpenCodeAuthAuthorization = Schema.Struct({
  url: Schema.String,
  method: Schema.Literals(["auto", "code"]),
  instructions: Schema.String
})
export type OpenCodeAuthAuthorization = typeof OpenCodeAuthAuthorization.Type

export const OpenCodeAuthFlow = Schema.Struct({
  id: Schema.String,
  accountId: Schema.String,
  providerId: Schema.String,
  state: Schema.Literals(["running", "waiting", "complete", "error"]),
  authorization: Schema.optional(OpenCodeAuthAuthorization),
  error: Schema.optional(Schema.String)
})
export type OpenCodeAuthFlow = typeof OpenCodeAuthFlow.Type

export const StartOpenCodeAuthRequest = Schema.Struct({
  methodId: Schema.String,
  inputs: Schema.optional(Schema.Record(Schema.String, Schema.String)),
  apiKey: Schema.optional(Schema.String)
})
export type StartOpenCodeAuthRequest = typeof StartOpenCodeAuthRequest.Type

export const AnswerOpenCodeAuthRequest = Schema.Struct({ code: Schema.String })
export type AnswerOpenCodeAuthRequest = typeof AnswerOpenCodeAuthRequest.Type

export const UpdateHarnessRequest = Schema.Struct({
  enabled: Schema.Boolean
})
export type UpdateHarnessRequest = typeof UpdateHarnessRequest.Type

export const McpTransport = Schema.Literals(["http", "stdio"])
export type McpTransport = typeof McpTransport.Type

export const McpAuthType = Schema.Literals(["none", "bearer", "oauth"])
export type McpAuthType = typeof McpAuthType.Type

export const DetectMcpAuthRequest = Schema.Struct({ url: Schema.String })
export type DetectMcpAuthRequest = typeof DetectMcpAuthRequest.Type

export const McpAuthDetection = Schema.Struct({
  authType: McpAuthType,
  detail: Schema.String,
  suggestedName: Schema.optional(Schema.String)
})
export type McpAuthDetection = typeof McpAuthDetection.Type

export const McpConnectionState = Schema.Literals([
  "disconnected",
  "connecting",
  "connected",
  "needsAuthorization",
  "expired",
  "error"
])
export type McpConnectionState = typeof McpConnectionState.Type

export const McpServer = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  transport: McpTransport,
  url: Schema.optional(Schema.String),
  command: Schema.optional(Schema.String),
  args: Schema.Array(Schema.String),
  headerNames: Schema.optional(Schema.Array(Schema.String)),
  environmentNames: Schema.optional(Schema.Array(Schema.String)),
  enabled: Schema.Boolean,
  authType: McpAuthType,
  oauthScope: Schema.optional(Schema.String),
  connectionState: McpConnectionState,
  toolCount: Schema.Number,
  detail: Schema.optional(Schema.String),
  createdAt: Schema.String,
  updatedAt: Schema.String
})
export type McpServer = typeof McpServer.Type

export const McpTool = Schema.Struct({
  serverId: Schema.String,
  serverName: Schema.String,
  name: Schema.String,
  title: Schema.optional(Schema.String),
  description: Schema.optional(Schema.String),
  inputSchema: Schema.Unknown
})
export type McpTool = typeof McpTool.Type

export const CreateMcpServerRequest = Schema.Struct({
  name: Schema.String,
  transport: McpTransport,
  url: Schema.optional(Schema.String),
  command: Schema.optional(Schema.String),
  args: Schema.optional(Schema.Array(Schema.String)),
  env: Schema.optional(Schema.Record(Schema.String, Schema.String)),
  headers: Schema.optional(Schema.Record(Schema.String, Schema.String)),
  enabled: Schema.optional(Schema.Boolean),
  authType: Schema.optional(McpAuthType),
  bearerToken: Schema.optional(Schema.String),
  oauthScope: Schema.optional(Schema.String),
  oauthClientId: Schema.optional(Schema.String),
  oauthClientSecret: Schema.optional(Schema.String)
})
export type CreateMcpServerRequest = typeof CreateMcpServerRequest.Type

export const UpdateMcpServerRequest = Schema.Struct({
  name: Schema.optional(Schema.String),
  enabled: Schema.optional(Schema.Boolean),
  url: Schema.optional(Schema.String),
  command: Schema.optional(Schema.String),
  args: Schema.optional(Schema.Array(Schema.String)),
  env: Schema.optional(Schema.Record(Schema.String, Schema.String)),
  headers: Schema.optional(Schema.Record(Schema.String, Schema.String)),
  removeEnv: Schema.optional(Schema.Array(Schema.String)),
  removeHeaders: Schema.optional(Schema.Array(Schema.String)),
  authType: Schema.optional(McpAuthType),
  bearerToken: Schema.optional(Schema.String),
  oauthScope: Schema.optional(Schema.String),
  oauthClientId: Schema.optional(Schema.String),
  oauthClientSecret: Schema.optional(Schema.String)
})
export type UpdateMcpServerRequest = typeof UpdateMcpServerRequest.Type

export const McpOAuthStartResponse = Schema.Struct({
  authorizationUrl: Schema.String
})
export type McpOAuthStartResponse = typeof McpOAuthStartResponse.Type

/// A session from a harness's own on-disk store (run before/outside
/// Codevisor) — the source for onboarding's workspace suggestions and
/// "import existing chats".
export const AgentSessionSummary = Schema.Struct({
  sessionId: Schema.String,
  cwd: Schema.String,
  title: Schema.optional(Schema.String),
  updatedAt: Schema.optional(Schema.String)
})
export type AgentSessionSummary = typeof AgentSessionSummary.Type

/// Codevisor's harness-independent mode vocabulary. Providers map their native
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

/// Transient work happening inside an active goal. Unlike the lifecycle
/// status, this may appear and disappear many times before the goal resolves.
export const GoalActivity = Schema.Literals(["planning", "verifying"])
export type GoalActivity = typeof GoalActivity.Type

/// A persistent per-session objective (codex "goal mode"). Snapshots are
/// idempotent full state: consumers replace, never accumulate.
export const SessionGoal = Schema.Struct({
  objective: Schema.String,
  status: GoalStatus,
  activity: Schema.optional(GoalActivity),
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
  locations: Schema.Array(ProjectLocation),
  /// The git remote this project was cloned from (projects added via
  /// /v1/projects/from-git). Machine-independent by design: any machine can
  /// materialize the same project by cloning the same remote.
  repoUrl: Schema.optional(Schema.String)
})
export type Project = typeof Project.Type

export const CreateProjectRequest = Schema.Struct({
  id: Schema.optional(Schema.String),
  folderPath: Schema.String,
  name: Schema.optional(Schema.String),
  isArchived: Schema.optional(Schema.Boolean),
  symbolName: Schema.optional(Schema.String),
  origin: Schema.optional(SessionOrigin),
  createdAt: Schema.optional(Schema.String),
  repoUrl: Schema.optional(Schema.String)
})
export type CreateProjectRequest = typeof CreateProjectRequest.Type

/// Clone a git remote into the machine's managed repos directory and register
/// the checkout as a project. The client-supplied id lets callers follow the
/// clone's project.setup progress events while the request is in flight (the
/// same trick as CreateWorktreeRequest.id).
export const CreateProjectFromGitRequest = Schema.Struct({
  id: Schema.optional(Schema.String),
  url: Schema.String,
  name: Schema.optional(Schema.String)
})
export type CreateProjectFromGitRequest = typeof CreateProjectFromGitRequest.Type

export const ProjectSetupState = Schema.Literals(["started", "log", "completed", "failed"])
export type ProjectSetupState = typeof ProjectSetupState.Type

/// Machine-readable failure category for clone errors, so clients can show
/// actionable guidance instead of raw git stderr.
export const ProjectSetupErrorCode = Schema.Literals([
  "auth_failed",
  "repo_not_found",
  "network",
  "disk_full",
  "invalid_url",
  "already_exists"
])
export type ProjectSetupErrorCode = typeof ProjectSetupErrorCode.Type

export const ProjectSetupUpdate = Schema.Struct({
  state: ProjectSetupState,
  projectId: Schema.String,
  url: Schema.String,
  stream: Schema.optional(Schema.Literals(["stdout", "stderr"])),
  line: Schema.optional(Schema.String),
  message: Schema.optional(Schema.String),
  code: Schema.optional(ProjectSetupErrorCode),
  durationMs: Schema.optional(Schema.Number)
})
export type ProjectSetupUpdate = typeof ProjectSetupUpdate.Type

export const FsEntry = Schema.Struct({
  name: Schema.String,
  path: Schema.String,
  isGitRepo: Schema.Boolean
})
export type FsEntry = typeof FsEntry.Type

/// A directory listing for the remote project picker: directories only, with
/// a git badge so repos stand out.
export const FsListResponse = Schema.Struct({
  path: Schema.String,
  parent: Schema.NullOr(Schema.String),
  entries: Schema.Array(FsEntry)
})
export type FsListResponse = typeof FsListResponse.Type

export const UpdateProjectRequest = Schema.Struct({
  name: Schema.optional(Schema.String),
  isArchived: Schema.optional(Schema.Boolean),
  symbolName: Schema.optional(Schema.String)
})
export type UpdateProjectRequest = typeof UpdateProjectRequest.Type

/// A pane workspace: the server-owned identity of one working surface inside
/// a project. It names the surface, points at the directory it works in (a
/// worktree path or the project folder), and owns sessions. Pane layout
/// (split trees) deliberately stays client-side.
export const Workspace = Schema.Struct({
  id: Schema.String,
  serverId: Schema.String,
  projectId: Schema.String,
  name: Schema.String,
  hasCustomName: Schema.Boolean,
  symbolName: Schema.optional(Schema.String),
  rootDirectory: Schema.optional(Schema.String),
  isArchived: Schema.Boolean,
  createdAt: Schema.String,
  updatedAt: Schema.optional(Schema.String)
})
export type Workspace = typeof Workspace.Type

export const UpsertWorkspaceRequest = Schema.Struct({
  /// Optional because the route path carries the id; when both are present
  /// they must match.
  id: Schema.optional(Schema.String),
  projectId: Schema.String,
  name: Schema.String,
  hasCustomName: Schema.Boolean,
  symbolName: Schema.optional(Schema.String),
  rootDirectory: Schema.optional(Schema.String),
  isArchived: Schema.optional(Schema.Boolean),
  /// Client backfills preserve the original creation date.
  createdAt: Schema.optional(Schema.String)
})
export type UpsertWorkspaceRequest = typeof UpsertWorkspaceRequest.Type

/// A workspace's scratchpad. The content is an opaque client-encoded blob
/// (`format` names the encoding) that the server stores and fans out verbatim;
/// writes are row-level last-write-wins with no merging.
export const WorkspaceNotes = Schema.Struct({
  workspaceId: Schema.String,
  content: Schema.String,
  format: Schema.String,
  updatedAt: Schema.String
})
export type WorkspaceNotes = typeof WorkspaceNotes.Type

export const UpsertWorkspaceNotesRequest = Schema.Struct({
  content: Schema.String,
  /// Omitted formats default server-side to "attributed-string-v1".
  format: Schema.optional(Schema.String),
  /// Clients send their local edit stamp so last-write-wins keeps fidelity;
  /// omitted stamps are generated server-side.
  updatedAt: Schema.optional(Schema.String)
})
export type UpsertWorkspaceNotesRequest = typeof UpsertWorkspaceNotesRequest.Type

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
  /// Optional Codevisor session id that should also receive mirrored
  /// `worktree.setup` progress while the session is waiting for first setup.
  sessionId: Schema.optional(Schema.String),
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
  /** Tokens currently occupying the model's context window. */
  used: Schema.optional(Schema.Number),
  /** Total model context-window size. */
  size: Schema.optional(Schema.Number),
  /** Cumulative token accounting for the whole harness session. */
  inputTokens: Schema.optional(Schema.Number),
  cachedInputTokens: Schema.optional(Schema.Number),
  outputTokens: Schema.optional(Schema.Number),
  reasoningOutputTokens: Schema.optional(Schema.Number),
  totalTokens: Schema.optional(Schema.Number),
  costAmount: Schema.optional(Schema.Number),
  costCurrency: Schema.optional(Schema.String),
  /** Whether the harness reported the amount or Codevisor estimated it. */
  costKind: Schema.optional(Schema.Literals(["reported", "estimated"]))
})
export type SessionUsage = typeof SessionUsage.Type

export const HarnessUsageWindow = Schema.Struct({
  id: Schema.String,
  label: Schema.String,
  usedPercent: Schema.Number,
  durationMinutes: Schema.optional(Schema.Number),
  resetsAt: Schema.optional(Schema.String)
})
export type HarnessUsageWindow = typeof HarnessUsageWindow.Type

export const HarnessUsageCredits = Schema.Struct({
  hasCredits: Schema.Boolean,
  unlimited: Schema.Boolean,
  balance: Schema.optional(Schema.String)
})
export type HarnessUsageCredits = typeof HarnessUsageCredits.Type

/** Account-level subscription limits for the harness account bound to a session. */
export const HarnessUsageLimits = Schema.Struct({
  state: Schema.Literals(["available", "unavailable"]),
  harnessId: Schema.String,
  accountId: Schema.optional(Schema.String),
  accountLabel: Schema.optional(Schema.String),
  accountEmail: Schema.optional(Schema.String),
  plan: Schema.optional(Schema.String),
  windows: Schema.Array(HarnessUsageWindow),
  credits: Schema.optional(HarnessUsageCredits),
  detail: Schema.optional(Schema.String),
  fetchedAt: Schema.String
})
export type HarnessUsageLimits = typeof HarnessUsageLimits.Type

export const BranchDiffTotals = Schema.Struct({
  added: Schema.Number,
  removed: Schema.Number
})
export type BranchDiffTotals = typeof BranchDiffTotals.Type

export const SessionSummary = Schema.Struct({
  id: Schema.String,
  projectId: Schema.String,
  serverId: Schema.String,
  harnessId: Schema.String,
  harnessAccountId: Schema.optional(Schema.String),
  agentSessionId: Schema.optional(Schema.String),
  title: Schema.String,
  origin: SessionOrigin,
  isArchived: Schema.Boolean,
  worktreeName: Schema.optional(Schema.String),
  /// The pane workspace this session belongs to, when a client has assigned
  /// one. Optional for sessions created before workspaces existed.
  workspaceId: Schema.optional(Schema.String),
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

/// A lightweight, stable row in the session transcript. Historical worked
/// details deliberately do not ride this payload; clients fetch those only
/// when the disclosure is opened.
export const TranscriptItem = Schema.Struct({
  id: Schema.String,
  sessionId: Schema.String,
  sequence: Schema.Number,
  role: Schema.Literals(["user", "assistant"]),
  text: Schema.String,
  createdAt: Schema.String,
  updatedAt: Schema.String,
  isGenerating: Schema.Boolean,
  hasDetails: Schema.Boolean,
  turnId: Schema.optional(Schema.String),
  startedAt: Schema.optional(Schema.String),
  endedAt: Schema.optional(Schema.String),
  stopReason: Schema.optional(Schema.String),
  stopDetail: Schema.optional(Schema.String),
  retryable: Schema.optional(Schema.Boolean),
  planDocument: Schema.optional(Schema.String),
  attachments: Schema.optional(Schema.Array(AttachmentRef)),
  revision: Schema.Number
})
export type TranscriptItem = typeof TranscriptItem.Type

/// Reverse-paginated transcript page. `items` are always oldest-to-newest for
/// direct display; `nextBefore` is opaque to clients.
export const TranscriptPage = Schema.Struct({
  items: Schema.Array(TranscriptItem),
  nextBefore: Schema.optional(Schema.String),
  hasMore: Schema.Boolean,
  eventCursor: Schema.Number,
  /** Current blocking question, snapshotted at the same revision as
   * `eventCursor` so a reconnect cannot skip the event that created it. */
  pendingQuestion: Schema.optional(QuestionPayload),
  backgroundTasks: Schema.optional(Schema.Array(BackgroundTask)),
  /** Latest durable goal snapshot at the same revision as `eventCursor`. */
  goal: Schema.optional(SessionGoal),
  /** Durable usage snapshot at the same revision as the transcript. */
  usage: Schema.optional(SessionUsage)
})
export type TranscriptPage = typeof TranscriptPage.Type

/// The raw events assigned to one assistant turn. CodevisorCore reduces this
/// bounded set only when the user expands historical worked details.
export const TranscriptItemDetails = Schema.Struct({
  itemId: Schema.String,
  revision: Schema.Number,
  events: Schema.Array(Schema.suspend(() => EventEnvelope))
})
export type TranscriptItemDetails = typeof TranscriptItemDetails.Type

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
  eventCursor: Schema.Number,
  pendingQuestion: Schema.optional(QuestionPayload),
  backgroundTasks: Schema.optional(Schema.Array(BackgroundTask)),
  goal: Schema.optional(SessionGoal)
})
export type SessionDetail = typeof SessionDetail.Type

export const CreateSessionRequest = Schema.Struct({
  id: Schema.optional(Schema.String),
  projectId: Schema.String,
  harnessId: Schema.String,
  harnessAccountId: Schema.optional(Schema.String),
  agentSessionId: Schema.optional(Schema.String),
  /// Create only the Codevisor session row. The server starts and persists the
  /// agent session on the first prompt/config/goal action.
  deferAgentSession: Schema.optional(Schema.Boolean),
  title: Schema.optional(Schema.String),
  origin: Schema.optional(SessionOrigin),
  isArchived: Schema.optional(Schema.Boolean),
  worktreeName: Schema.optional(Schema.String),
  /// Create the session already belonging to a pane workspace.
  workspaceId: Schema.optional(Schema.String),
  createdAt: Schema.optional(Schema.String),
  updatedAt: Schema.optional(Schema.String)
})
export type CreateSessionRequest = typeof CreateSessionRequest.Type

export const UpdateSessionRequest = Schema.Struct({
  agentSessionId: Schema.optional(Schema.String),
  isArchived: Schema.optional(Schema.Boolean),
  title: Schema.optional(Schema.String),
  worktreeName: Schema.optional(Schema.String),
  /// Explicit activity stamp, sent only when a turn finishes; plain metadata
  /// updates must omit it so recency ordering ignores opens/renames.
  updatedAt: Schema.optional(Schema.String)
})
export type UpdateSessionRequest = typeof UpdateSessionRequest.Type

export const PromptRequest = Schema.Struct({
  text: Schema.String,
  clientActionId: Schema.optional(Schema.String),
  attachments: Schema.optional(Schema.Array(AttachmentRef)),
  /// The client's id for its optimistic user message. It becomes the queue
  /// item id — and therefore the `messageId` on the user echo event — so
  /// clients can reconcile the echo with the optimistic append by IDENTITY
  /// instead of content matching.
  messageId: Schema.optional(Schema.String)
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
  database: Schema.Literals(["ready", "migrating", "failed"]),
  migration: Schema.optional(
    Schema.Struct({
      id: Schema.String,
      name: Schema.String,
      completed: Schema.Number,
      total: Schema.Number,
      error: Schema.optional(Schema.String)
    })
  )
})
export type HealthResponse = typeof HealthResponse.Type

export const ServerInfo = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  kind: ServerKind,
  version: Schema.String,
  platform: Schema.String,
  bindHost: Schema.String,
  features: Schema.optional(Schema.Array(Schema.String)),
  /// Stable machine identity persisted with the database; unlike `id` it
  /// survives --serverId defaults and renames. Optional for older servers.
  machineId: Schema.optional(Schema.String),
  arch: Schema.optional(Schema.String),
  hostname: Schema.optional(Schema.String)
})
export type ServerInfo = typeof ServerInfo.Type

/// Minimal tokenless manifest served at /v1/discovery so clients can find
/// Codevisor servers on a private network (e.g. tailnet peers) before pairing.
/// Deliberately excludes anything sensitive — pairing still requires a token.
export const DiscoveryInfo = Schema.Struct({
  serverId: Schema.String,
  machineId: Schema.String,
  name: Schema.String,
  kind: ServerKind,
  version: Schema.String,
  platform: Schema.String,
  hostname: Schema.String
})
export type DiscoveryInfo = typeof DiscoveryInfo.Type

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
  "project.setup",
  "worktree.created",
  "worktree.setup",
  "workspace.updated",
  "workspace.deleted",
  "workspace.notes.updated",
  "session.created",
  "session.updated",
  "session.archived",
  "session.deleted",
  "session.output",
  "session.queue.updated",
  "session.error",
  "session.authRequired",
  "harness.auth.updated",
  "harness.account.updated",
  "harness.authFlow.updated",
  "terminal.output",
  "terminal.exit",
  "update.changed"
])
export type EventKind = typeof EventKind.Type

export const EventEnvelope = Schema.Struct({
  id: Schema.Number,
  /// Global shell-log cursor when this event also changes project/session
  /// metadata. Chat-only events intentionally omit it.
  globalEventId: Schema.optional(Schema.Number),
  /// Monotonic sequence within `subjectId`. Session-scoped streams use this
  /// cursor so an unrelated project/session event can never invalidate a
  /// chat's resume position.
  subjectRevision: Schema.optional(Schema.Number),
  serverId: Schema.String,
  kind: EventKind,
  subjectId: Schema.String,
  createdAt: Schema.String,
  payload: Schema.Unknown
})
export type EventEnvelope = typeof EventEnvelope.Type

export const DataUpgradeProgress = Schema.Struct({
  state: Schema.Literals(["running", "completed", "failed"]),
  id: Schema.String,
  name: Schema.String,
  completed: Schema.Number,
  total: Schema.Number,
  error: Schema.optional(Schema.String)
})
export type DataUpgradeProgress = typeof DataUpgradeProgress.Type

export const TerminalCreateRequest = Schema.Struct({
  sessionId: Schema.String,
  cwd: Schema.String,
  cols: Schema.Number,
  rows: Schema.Number,
  shell: Schema.optional(Schema.String),
  args: Schema.optional(Schema.Array(Schema.String)),
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

export * from "./openapi.js"

export const decode =
  <S extends Schema.ConstraintDecoder<unknown>>(schema: S) =>
  (input: unknown): S["Type"] =>
    Schema.decodeUnknownSync(schema)(input)

export const encode =
  <S extends Schema.ConstraintEncoder<unknown>>(schema: S) =>
  (input: S["Type"]): S["Encoded"] =>
    Schema.encodeSync(schema)(input)
