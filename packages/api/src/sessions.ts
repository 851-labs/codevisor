import { Schema } from "effect"

import { SessionAutoResume } from "./auto-resume.js"
import { Labels } from "./labels.js"
import { CreateProjectRequest } from "./projects.js"
import { GoalStatus, SessionGoal, SessionOrigin, SessionSkills } from "./session-config.js"
import {
  BackgroundTask,
  MessagePhase,
  QuestionAnswerEntry,
  QuestionOutcome,
  QuestionPayload,
  QuestionPresentation,
  QuestionSpec,
  SessionPlan,
  TurnStopKind
} from "./session-updates.js"
import { WorkspacePosition } from "./workspace-position.js"

export const SessionUsage = Schema.Struct({
  used: Schema.optional(Schema.Number),
  size: Schema.optional(Schema.Number),
  inputTokens: Schema.optional(Schema.Number),
  cachedInputTokens: Schema.optional(Schema.Number),
  outputTokens: Schema.optional(Schema.Number),
  reasoningOutputTokens: Schema.optional(Schema.Number),
  totalTokens: Schema.optional(Schema.Number),
  costAmount: Schema.optional(Schema.Number),
  costCurrency: Schema.optional(Schema.String),
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

export const SessionContextCategory = Schema.Struct({
  name: Schema.String,
  tokens: Schema.Number,
  color: Schema.optional(Schema.String),
  isDeferred: Schema.optional(Schema.Boolean)
})
export type SessionContextCategory = typeof SessionContextCategory.Type

export const SessionContextTool = Schema.Struct({
  name: Schema.String,
  serverName: Schema.String,
  tokens: Schema.Number,
  isLoaded: Schema.optional(Schema.Boolean)
})
export type SessionContextTool = typeof SessionContextTool.Type

export const SessionContext = Schema.Struct({
  model: Schema.optional(Schema.String),
  totalTokens: Schema.Number,
  maxTokens: Schema.Number,
  categories: Schema.Array(SessionContextCategory),
  mcpTools: Schema.Array(SessionContextTool)
})
export type SessionContext = typeof SessionContext.Type

export const BranchDiffTotals = Schema.Struct({
  added: Schema.Number,
  removed: Schema.Number
})
export type BranchDiffTotals = typeof BranchDiffTotals.Type

export const SessionSidebarState = Schema.Literals([
  "idle",
  "inProgress",
  "waitingForUser",
  "unread",
  "errored"
])
export type SessionSidebarState = typeof SessionSidebarState.Type

export const BotMessagePreview = Schema.Struct({
  text: Schema.String,
  attachmentNames: Schema.Array(Schema.String)
})
export type BotMessagePreview = typeof BotMessagePreview.Type

export const SessionSummary = Schema.Struct({
  id: Schema.String,
  projectId: Schema.String,
  serverId: Schema.String,
  harnessId: Schema.String,
  harnessAccountId: Schema.optional(Schema.String),
  agentSessionId: Schema.optional(Schema.String),
  title: Schema.String,
  origin: SessionOrigin,
  worktreeName: Schema.optional(Schema.String),
  workspaceId: Schema.optional(Schema.String),
  cwd: Schema.optional(Schema.String),
  configSelections: Schema.optional(Schema.Record(Schema.String, Schema.String)),
  unavailableConfigSelections: Schema.optional(Schema.Record(Schema.String, Schema.String)),
  createdAt: Schema.String,
  updatedAt: Schema.optional(Schema.String),
  sidebarState: Schema.optional(SessionSidebarState),
  sidebarStateChangedAt: Schema.optional(Schema.String),
  usage: Schema.optional(SessionUsage),
  latestAttentionSequence: Schema.optional(Schema.Number),
  lastSeenAttentionSequence: Schema.optional(Schema.Number),
  unreadCount: Schema.optional(Schema.Number),
  hasUnreadError: Schema.optional(Schema.Boolean),
  actionRequired: Schema.optional(Schema.Boolean),
  actionRequiredKind: Schema.optional(Schema.Literals(["question", "planApproval"])),
  pendingPlanApproval: Schema.optional(Schema.Boolean),
  latestBotMessage: Schema.optional(BotMessagePreview),
  parentSessionId: Schema.optional(Schema.String),
  labels: Schema.optional(Labels)
})
export type SessionSummary = typeof SessionSummary.Type

export const ConversationRole = Schema.Literals(["user", "assistant", "system"])
export type ConversationRole = typeof ConversationRole.Type

export const AttachmentKind = Schema.Literals(["image", "file"])
export type AttachmentKind = typeof AttachmentKind.Type

export const AttachmentRef = Schema.Struct({
  fileId: Schema.String,
  name: Schema.String,
  mimeType: Schema.String,
  sizeBytes: Schema.Number,
  kind: AttachmentKind
})
export type AttachmentRef = typeof AttachmentRef.Type

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

export const TranscriptBodyResource = Schema.Struct({
  itemId: Schema.String,
  entryKey: Schema.String,
  fields: Schema.Array(
    Schema.Struct({
      name: Schema.String,
      revision: Schema.Number,
      encoding: Schema.Literals(["text", "json"]),
      sizeBytes: Schema.Number,
      pageCount: Schema.optional(Schema.Number),
      generation: Schema.optional(Schema.Number)
    })
  )
})
export type TranscriptBodyResource = typeof TranscriptBodyResource.Type

export const TranscriptSetupRequest = Schema.Struct({
  questionId: Schema.String,
  presentation: QuestionPresentation,
  outcome: Schema.optional(QuestionOutcome)
})
export type TranscriptSetupRequest = typeof TranscriptSetupRequest.Type

export const TranscriptQuestionInteraction = Schema.Struct({
  id: Schema.String,
  kind: Schema.Literal("question"),
  payload: Schema.Struct({
    message: Schema.optional(Schema.String),
    questions: Schema.Array(QuestionSpec)
  }),
  answer: Schema.optional(
    Schema.Struct({
      outcome: QuestionOutcome,
      answers: Schema.optional(Schema.Record(Schema.String, QuestionAnswerEntry))
    })
  )
})
export type TranscriptQuestionInteraction = typeof TranscriptQuestionInteraction.Type

export const TranscriptInteraction = Schema.Union([TranscriptQuestionInteraction])
export type TranscriptInteraction = typeof TranscriptInteraction.Type

export const PromptAttribution = Schema.Struct({
  kind: Schema.Literal("app"),
  viewId: Schema.String,
  plugin: Schema.String
})
export type PromptAttribution = typeof PromptAttribution.Type

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
  stopKind: Schema.optional(TurnStopKind),
  retryable: Schema.optional(Schema.Boolean),
  planDocument: Schema.optional(Schema.String),
  planProposedAt: Schema.optional(Schema.String),
  planResumedAt: Schema.optional(Schema.String),
  attachments: Schema.optional(Schema.Array(AttachmentRef)),
  messageId: Schema.optional(Schema.String),
  phase: Schema.optional(MessagePhase),
  origin: Schema.optional(Schema.Literals(["event"])),
  attribution: Schema.optional(PromptAttribution),
  textResource: Schema.optional(TranscriptBodyResource),
  planResource: Schema.optional(TranscriptBodyResource),
  textGeneration: Schema.optional(Schema.Number),
  textRevision: Schema.optional(Schema.Number),
  textPosition: Schema.optional(Schema.Number),
  setupRequests: Schema.optional(Schema.Array(TranscriptSetupRequest)),
  interactions: Schema.optional(Schema.Array(TranscriptInteraction)),
  revision: Schema.Number
})
export type TranscriptItem = typeof TranscriptItem.Type

export const SessionUpdateGate = Schema.Struct({
  harnessId: Schema.String,
  harnessName: Schema.String
})
export type SessionUpdateGate = typeof SessionUpdateGate.Type

export const TranscriptPage = Schema.Struct({
  items: Schema.Array(TranscriptItem),
  nextBefore: Schema.optional(Schema.String),
  nextAfter: Schema.optional(Schema.String),
  hasNewer: Schema.Boolean,
  hasMore: Schema.Boolean,
  eventCursor: Schema.Number,
  stateUpdates: Schema.Array(Schema.Unknown),
  setupActivities: Schema.Array(Schema.Unknown),
  pendingQuestion: Schema.optional(QuestionPayload),
  pendingPlanApproval: Schema.optional(Schema.Boolean),
  backgroundTasks: Schema.optional(Schema.Array(BackgroundTask)),
  goal: Schema.optional(SessionGoal),
  skills: Schema.optional(SessionSkills),
  sessionPlan: Schema.optional(SessionPlan),
  usage: Schema.optional(SessionUsage),
  updateGate: Schema.optional(SessionUpdateGate),
  autoResume: Schema.optional(SessionAutoResume)
})
export type TranscriptPage = typeof TranscriptPage.Type

export const TranscriptItemDetails = Schema.Struct({
  itemId: Schema.String,
  revision: Schema.Number,
  eventCursor: Schema.Number,
  entries: Schema.Array(
    Schema.Struct({
      key: Schema.String,
      position: Schema.Number,
      revision: Schema.Number,
      payload: Schema.Unknown
    })
  ),
  nextAfter: Schema.optional(Schema.String),
  previousBefore: Schema.optional(Schema.String)
})
export type TranscriptItemDetails = typeof TranscriptItemDetails.Type

export const TranscriptBodyPage = Schema.Struct({
  revision: Schema.Number,
  encoding: Schema.Literals(["text", "json"]),
  text: Schema.String,
  position: Schema.Number,
  nextPosition: Schema.optional(Schema.Number)
})
export type TranscriptBodyPage = typeof TranscriptBodyPage.Type

export const PromptOrigin = Schema.Literals(["user", "system"])
export type PromptOrigin = typeof PromptOrigin.Type

export const PromptQueueItem = Schema.Struct({
  id: Schema.String,
  sessionId: Schema.String,
  text: Schema.String,
  createdAt: Schema.String,
  updatedAt: Schema.String,
  attachments: Schema.optional(Schema.Array(AttachmentRef)),
  clientId: Schema.optional(Schema.String),
  origin: Schema.optional(PromptOrigin),
  attribution: Schema.optional(PromptAttribution)
})
export type PromptQueueItem = typeof PromptQueueItem.Type

export const SessionDetail = Schema.Struct({
  hasMore: Schema.Boolean,
  nextBefore: Schema.optional(Schema.String),
  session: SessionSummary,
  conversation: Schema.Array(ConversationItem),
  promptQueue: Schema.Array(PromptQueueItem),
  eventCursor: Schema.Number,
  pendingQuestion: Schema.optional(QuestionPayload),
  pendingPlanApproval: Schema.optional(Schema.Boolean),
  backgroundTasks: Schema.optional(Schema.Array(BackgroundTask)),
  goal: Schema.optional(SessionGoal),
  sessionPlan: Schema.optional(SessionPlan),
  updateGate: Schema.optional(SessionUpdateGate),
  autoResume: Schema.optional(SessionAutoResume)
})
export type SessionDetail = typeof SessionDetail.Type

export const CreateSessionRequest = Schema.Struct({
  sidebarOrderHead: Schema.optional(WorkspacePosition),
  sidebarPosition: Schema.optional(WorkspacePosition),
  id: Schema.optional(Schema.String),
  projectId: Schema.String,
  harnessId: Schema.String,
  harnessAccountId: Schema.optional(Schema.String),
  agentSessionId: Schema.optional(Schema.String),
  deferAgentSession: Schema.optional(Schema.Boolean),
  title: Schema.optional(Schema.String),
  origin: Schema.optional(SessionOrigin),
  worktreeName: Schema.optional(Schema.String),
  workspaceId: Schema.optional(Schema.String),
  parentSessionId: Schema.optional(Schema.String),
  labels: Schema.optional(Labels),
  configSelections: Schema.optional(Schema.Record(Schema.String, Schema.String)),
  createdAt: Schema.optional(Schema.String),
  updatedAt: Schema.optional(Schema.String)
})
export type CreateSessionRequest = typeof CreateSessionRequest.Type

export const UpdateSessionRequest = Schema.Struct({
  sidebarOrderHead: Schema.optional(WorkspacePosition),
  sidebarPosition: Schema.optional(WorkspacePosition),
  agentSessionId: Schema.optional(Schema.String),
  title: Schema.optional(Schema.String),
  titleIntent: Schema.optional(Schema.Literals(["fallback", "rename"])),
  worktreeName: Schema.optional(Schema.String),
  projectId: Schema.optional(Schema.String),
  workspaceId: Schema.optional(Schema.String),
  harnessId: Schema.optional(Schema.String),
  harnessAccountId: Schema.optional(Schema.String),
  labels: Schema.optional(Labels),
  updatedAt: Schema.optional(Schema.String)
})
export type UpdateSessionRequest = typeof UpdateSessionRequest.Type

export const MarkSessionReadRequest = Schema.Struct({
  throughSequence: Schema.Number
})
export type MarkSessionReadRequest = typeof MarkSessionReadRequest.Type

export const OpenSessionRequest = Schema.Struct({
  project: Schema.optional(CreateProjectRequest),
  session: CreateSessionRequest,
  update: Schema.optional(UpdateSessionRequest),
  transcriptLimit: Schema.optional(Schema.Number)
})
export type OpenSessionRequest = typeof OpenSessionRequest.Type

export const OpenSessionResponse = Schema.Struct({
  session: SessionSummary,
  transcript: TranscriptPage,
  runtime: Schema.Unknown
})
export type OpenSessionResponse = typeof OpenSessionResponse.Type

export const PromptDelivery = Schema.Literals(["steer", "queue"])
export type PromptDelivery = typeof PromptDelivery.Type

export const PromptDelivered = Schema.Literals(["sent", "steered", "queued"])
export type PromptDelivered = typeof PromptDelivered.Type

export const PromptRequest = Schema.Struct({
  text: Schema.String,
  delivery: Schema.optional(PromptDelivery),
  clientActionId: Schema.optional(Schema.String),
  attachments: Schema.optional(Schema.Array(AttachmentRef)),
  messageId: Schema.optional(Schema.String),
  clientId: Schema.optional(Schema.String),
  fromSessionId: Schema.optional(Schema.String),
  attribution: Schema.optional(PromptAttribution)
})
export type PromptRequest = typeof PromptRequest.Type

export const PromptAcceptedResponse = Schema.Struct({
  accepted: Schema.Boolean,
  sessionId: Schema.String,
  queueItemId: Schema.optional(Schema.String),
  delivered: Schema.optional(PromptDelivered),
  steerDeclined: Schema.optional(Schema.Boolean)
})
export type PromptAcceptedResponse = typeof PromptAcceptedResponse.Type

export const UpdateQueuedPromptRequest = Schema.Struct({
  text: Schema.String,
  attachments: Schema.optional(Schema.Array(AttachmentRef))
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

export const SetGoalRequest = Schema.Struct({
  objective: Schema.optional(Schema.String),
  status: Schema.optional(GoalStatus),
  tokenBudget: Schema.optional(Schema.NullOr(Schema.Number)),
  clientActionId: Schema.optional(Schema.String)
})
export type SetGoalRequest = typeof SetGoalRequest.Type

export const SetQuestionAnswerRequest = Schema.Struct({
  outcome: Schema.Literals(["answered", "cancelled"]),
  answers: Schema.optional(Schema.Record(Schema.String, QuestionAnswerEntry)),
  clientActionId: Schema.optional(Schema.String)
})
export type SetQuestionAnswerRequest = typeof SetQuestionAnswerRequest.Type
