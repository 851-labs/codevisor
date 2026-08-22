import { Schema } from "effect"
import { BackgroundTask, QuestionAnswerEntry, QuestionPayload } from "./session-updates.js"
import { GoalStatus, SessionGoal, SessionOrigin } from "./session-config.js"
import { CreateProjectRequest } from "./projects.js"
import { EventEnvelope } from "./events.js"

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

/** The mutually exclusive state rendered by native session sidebars. The
 *  ordering priority is a presentation concern; this value records only what
 *  the row currently shows so repeated events inside one state do not refresh
 *  its ordering timestamp. */
export const SessionSidebarState = Schema.Literals([
  "idle",
  "inProgress",
  "waitingForUser",
  "unread",
  "errored"
])
export type SessionSidebarState = typeof SessionSidebarState.Type

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
  archivedAt: Schema.optional(Schema.String),
  worktreeName: Schema.optional(Schema.String),
  /// The pane workspace this session belongs to, when a client has assigned
  /// one. Optional for sessions created before workspaces existed.
  workspaceId: Schema.optional(Schema.String),
  cwd: Schema.optional(Schema.String),
  /// Last configuration values accepted for this chat. Clients combine this
  /// small snapshot with cached option metadata to paint the previous
  /// composer configuration while the harness validates it.
  configSelections: Schema.optional(Schema.Record(Schema.String, Schema.String)),
  createdAt: Schema.String,
  updatedAt: Schema.optional(Schema.String),
  /** Native-sidebar state and the moment that visible state was entered.
   *  Optional while native clients may connect to older servers. */
  sidebarState: Schema.optional(SessionSidebarState),
  sidebarStateChangedAt: Schema.optional(Schema.String),
  usage: Schema.optional(SessionUsage),
  /** Monotonic server-owned attention revision: every settled turn advances
   * it by one. Unread = revision ahead of `lastSeenAttentionSequence`.
   * Optional for compatibility with servers that predate durable
   * cross-device read state. */
  latestAttentionSequence: Schema.optional(Schema.Number),
  /** The latest attention revision read by the owner on any device. Clients
   * advance it when the chat is the focused pane (macOS) or the foregrounded
   * screen (iOS) — there is no per-row read receipt. */
  lastSeenAttentionSequence: Schema.optional(Schema.Number),
  unreadCount: Schema.optional(Schema.Number),
  /** The last settled turn errored and has not been acknowledged. Ranks in
   * the action-required tier (sidebarState `errored`) but clears on read —
   * it is the urgent flavor of unread, not a lock. */
  hasUnreadError: Schema.optional(Schema.Boolean),
  /** Intrinsic blocking state (question/plan approval); reading the session
   * does not clear it. */
  actionRequired: Schema.optional(Schema.Boolean),
  actionRequiredKind: Schema.optional(Schema.Literals(["question", "planApproval"])),
  /** Durable form of Codex's synthetic post-plan approval prompt. */
  pendingPlanApproval: Schema.optional(Schema.Boolean)
})
export type SessionSummary = typeof SessionSummary.Type

export const ConversationRole = Schema.Literals(["user", "assistant", "system"])
export type ConversationRole = typeof ConversationRole.Type

export const AttachmentKind = Schema.Literals(["image", "file"])
export type AttachmentKind = typeof AttachmentKind.Type

/// A reference to an immutable file (`POST /v1/files`) carried by either side
/// of the conversation; bytes are fetched via `GET /v1/files/:id`.
export const AttachmentRef = Schema.Struct({
  fileId: Schema.String,
  name: Schema.String,
  mimeType: Schema.String,
  sizeBytes: Schema.Number,
  kind: AttachmentKind
})
export type AttachmentRef = typeof AttachmentRef.Type

/** Durable semantic replacement for the assistant's terminal Markdown. The
 * server emits it immediately before turn completion after promoting local
 * artifact links into immutable files. Clients that do not know this update
 * safely ignore it and still receive the ordinary assistant stream. */
export const AssistantMessageFinalizedPayload = Schema.Struct({
  sessionUpdate: Schema.Literal("assistant_message_finalized"),
  markdown: Schema.String,
  messageId: Schema.optional(Schema.String),
  attachments: Schema.Array(AttachmentRef)
})
export type AssistantMessageFinalizedPayload = typeof AssistantMessageFinalizedPayload.Type

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
  /** Provider message id of the still-streaming final text span. Present only
   * while an assistant item is generating, so a client restoring mid-stream
   * can give the snapshot text the same identity live deltas use and merge
   * them into one span instead of splitting the message in two. */
  messageId: Schema.optional(Schema.String),
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
  /** Always emitted by current servers. Optional in the decoder so clients
   * can still open sessions hosted by a pre-attention-state server. */
  pendingPlanApproval: Schema.optional(Schema.Boolean),
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
  /** Always emitted by current servers; optional only for rolling-upgrade
   * compatibility with servers that predate durable plan approval. */
  pendingPlanApproval: Schema.optional(Schema.Boolean),
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
  /// Move the session to another project before its agent starts. Used when a
  /// scratch workspace locks in its real project on the first send; the server
  /// rejects the move once an agent session exists (the cwd is already bound).
  projectId: Schema.optional(Schema.String),
  /// Assign an existing session to its server-owned pane workspace. Native
  /// clients create chats before their first connection, so this must be
  /// accepted on update as well as create.
  workspaceId: Schema.optional(Schema.String),
  /// Sessions created EAGERLY (before the composer chose a harness) carry
  /// harnessId "" — the first send patches the real choice here so the
  /// deferred agent starts under the right harness/account.
  harnessId: Schema.optional(Schema.String),
  harnessAccountId: Schema.optional(Schema.String),
  /// Explicit activity stamp, sent only when a turn finishes; plain metadata
  /// updates must omit it so recency ordering ignores opens/renames.
  updatedAt: Schema.optional(Schema.String)
})
export type UpdateSessionRequest = typeof UpdateSessionRequest.Type

export const MarkSessionReadRequest = Schema.Struct({
  /** Advance through exactly the state the client rendered. Required so a
   * delayed request can never consume attention created after the view closed. */
  throughSequence: Schema.Number
})
export type MarkSessionReadRequest = typeof MarkSessionReadRequest.Type

/// One-round-trip chat open: ensure the project and session records exist and
/// return the first transcript page together. Replaces the discrete
/// listProjects → createProject → listSessions → create/update → transcript
/// sequence, whose 3–4 serial round-trips delayed the first transcript paint
/// on every chat open (whole seconds over high-latency remote links).
export const OpenSessionRequest = Schema.Struct({
  /// Create-if-missing. An existing project is deliberately never updated
  /// from this snapshot: it was taken when the client's draft was created,
  /// and pushing it on open could revert changes made in the meantime
  /// (e.g. un-archiving an archived project).
  project: Schema.optional(CreateProjectRequest),
  /// Used only when the session does not exist yet. Its `id`, when present,
  /// must match the id in the path.
  session: CreateSessionRequest,
  /// Applied when the session already exists — the same fields the discrete
  /// PATCH used to send while opening.
  update: Schema.optional(UpdateSessionRequest),
  /// First transcript page size (same default as GET …/transcript).
  transcriptLimit: Schema.optional(Schema.Number)
})
export type OpenSessionRequest = typeof OpenSessionRequest.Type

export const OpenSessionResponse = Schema.Struct({
  session: SessionSummary,
  transcript: TranscriptPage
})
export type OpenSessionResponse = typeof OpenSessionResponse.Type

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

export const ReorderQueuedPromptsRequest = Schema.Struct({
  queueItemIds: Schema.Array(Schema.String)
})
export type ReorderQueuedPromptsRequest = typeof ReorderQueuedPromptsRequest.Type

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
