import { Schema } from "effect"

/** Added/removed line counts for one file touched by a tool call. Values are
 *  cumulative for the tool call; each update replaces the previous stats. */
export const DiffStat = Schema.Struct({
  path: Schema.String,
  added: Schema.Number,
  removed: Schema.Number
})
export type DiffStat = typeof DiffStat.Type

export const ToolCallStatus = Schema.Literals([
  "pending",
  "in_progress",
  "completed",
  "failed",
  "cancelled"
])
export type ToolCallStatus = typeof ToolCallStatus.Type

export const TurnInitiator = Schema.Literals(["user", "agent"])
export type TurnInitiator = typeof TurnInitiator.Type

/** Turn lifecycle payload carried on `session.updated` envelopes. Turn ends
 *  keep the legacy `{ stopReason }` shape so older clients continue to detect
 *  completion; `turnState: "started"` is ignored by clients that predate it. */
export const TurnLifecycle = Schema.Struct({
  turnId: Schema.String,
  turnState: Schema.Literals(["started", "ended"]),
  initiatedBy: TurnInitiator,
  stopReason: Schema.optional(Schema.String)
})
export type TurnLifecycle = typeof TurnLifecycle.Type

/** Tool-call payload carried on `session.output` envelopes, discriminated by
 *  `sessionUpdate`. Extends the ACP shape with `diffStats` (per-path counts,
 *  streamed while a provider can observe the edit being generated) and
 *  `parentToolCallId` (subagent attribution). Streaming progress rides as a
 *  plain `tool_call_update` carrying only `toolCallId` + `diffStats`. */
export const ToolCallPayload = Schema.Struct({
  sessionUpdate: Schema.Literals(["tool_call", "tool_call_update"]),
  toolCallId: Schema.String,
  title: Schema.optional(Schema.String),
  kind: Schema.optional(Schema.String),
  status: Schema.optional(ToolCallStatus),
  diffStats: Schema.optional(Schema.Array(DiffStat)),
  parentToolCallId: Schema.optional(Schema.String),
  content: Schema.optional(Schema.Unknown),
  locations: Schema.optional(Schema.Unknown),
  rawInput: Schema.optional(Schema.Unknown),
  rawOutput: Schema.optional(Schema.Unknown),
  _meta: Schema.optional(Schema.Unknown)
})
export type ToolCallPayload = typeof ToolCallPayload.Type

/** Finality of an agent message span, when the provider can tell. `final` is
 *  the turn's terminal answer (streams with final styling from the first
 *  chunk); `commentary` is mid-turn narration that never becomes the answer.
 *  Absent means unknown — clients render optimistically (last text span wins).
 *  A zero-length chunk carrying `phase` retro-tags an already-streamed span by
 *  `messageId` (e.g. Claude text demoted to commentary once a tool call
 *  starts in the same assistant message). */
export const MessagePhase = Schema.Literals(["commentary", "final"])
export type MessagePhase = typeof MessagePhase.Type

/** Message/thought chunk payload carried on `session.output` envelopes.
 *  `parentToolCallId` attributes a chunk to a subagent's parent tool call so
 *  clients can nest subagent transcripts; chunks without it belong to the main
 *  agent. `messageId` keys text spans so history replay dedupes streamed text. */
export const AgentChunkPayload = Schema.Struct({
  sessionUpdate: Schema.Literals([
    "agent_message_chunk",
    "agent_thought_chunk",
    "user_message_chunk"
  ]),
  content: Schema.Unknown,
  messageId: Schema.optional(Schema.String),
  parentToolCallId: Schema.optional(Schema.String),
  phase: Schema.optional(MessagePhase)
})
export type AgentChunkPayload = typeof AgentChunkPayload.Type

/** One in-flight background task (backgrounded shell, subagent, etc.) owned by
 *  the agent process. `toolUseId` links the task back to the tool call that
 *  spawned it, when known. `terminalKey` is set when the task's process output
 *  streams through a server-owned terminal — clients attach to it with the
 *  regular terminal API (`POST /v1/terminals` with `sessionId: terminalKey`,
 *  `attachOnly: true`) and render it as a live terminal tab. */
export const BackgroundTask = Schema.Struct({
  id: Schema.String,
  description: Schema.String,
  status: Schema.String,
  taskType: Schema.String,
  toolUseId: Schema.optional(Schema.String),
  terminalKey: Schema.optional(Schema.String),
  /** The terminal is a read-only mirror: the provider cannot forward input
   *  or kill the process (codex owns its command executions). Clients hide
   *  the kill affordance while the task runs. */
  readOnly: Schema.optional(Schema.Boolean)
})
export type BackgroundTask = typeof BackgroundTask.Type

/** Background-task payload carried on `session.updated` envelopes. Each
 *  emission is a full snapshot that replaces the previous one; an empty array
 *  means no background work is pending. Tasks legitimately span turns — a
 *  non-empty snapshot after `turnState: "ended"` means the agent is waiting on
 *  background work and will start an agent-initiated turn when it settles. */
export const BackgroundTasksPayload = Schema.Struct({
  backgroundTasks: Schema.Array(BackgroundTask)
})
export type BackgroundTasksPayload = typeof BackgroundTasksPayload.Type
/** Plan-document payload carried on `session.output` envelopes. A free-form
 *  markdown plan the agent proposes before implementing (Claude plan mode's
 *  ExitPlanMode, codex plan-mode plan items) — distinct from the ACP `plan`
 *  step checklist. Replace-per-turn semantics, like `plan`. */
export const PlanDocumentPayload = Schema.Struct({
  sessionUpdate: Schema.Literals(["plan_document"]),
  markdown: Schema.String
})
export type PlanDocumentPayload = typeof PlanDocumentPayload.Type

export const QuestionOption = Schema.Struct({
  label: Schema.String,
  description: Schema.optional(Schema.String)
})
export type QuestionOption = typeof QuestionOption.Type

/** One question inside a question request. `allowsOther` adds the free-text
 *  affordance; `isSecret` masks that free-text input. */
export const QuestionSpec = Schema.Struct({
  id: Schema.String,
  header: Schema.optional(Schema.String),
  question: Schema.String,
  options: Schema.Array(QuestionOption),
  multiSelect: Schema.optional(Schema.Boolean),
  allowsOther: Schema.Boolean,
  isSecret: Schema.optional(Schema.Boolean)
})
export type QuestionSpec = typeof QuestionSpec.Type

/** Agent-asked question payload carried on `session.output` envelopes. The
 *  agent's turn BLOCKS until the client answers via
 *  `POST /v1/sessions/:id/questions/:questionId/answer` (or the provider
 *  auto-resolves after `autoResolutionMs`). Resolution arrives as a paired
 *  `question_resolved` event with the same `questionId` — events are
 *  append-only, so clients collapse the pair on replay. */
export const QuestionPayload = Schema.Struct({
  sessionUpdate: Schema.Literals(["question"]),
  questionId: Schema.String,
  /** Context line shown above the questions (e.g. an MCP server's
   *  elicitation message). */
  message: Schema.optional(Schema.String),
  questions: Schema.Array(QuestionSpec),
  autoResolutionMs: Schema.optional(Schema.Number)
})
export type QuestionPayload = typeof QuestionPayload.Type

export const QuestionOutcome = Schema.Literals(["answered", "cancelled", "autoResolved"])
export type QuestionOutcome = typeof QuestionOutcome.Type

/** Per-question answer: selected option labels (or the free-text entry),
 *  plus an optional note the user typed alongside a selection. */
export const QuestionAnswerEntry = Schema.Struct({
  answers: Schema.Array(Schema.String),
  note: Schema.optional(Schema.String)
})
export type QuestionAnswerEntry = typeof QuestionAnswerEntry.Type

/** Terminal event for a question request. Carries the questions and answers
 *  so the transcript can render an answered-question card without joining
 *  the original `question` event. */
export const QuestionResolvedPayload = Schema.Struct({
  sessionUpdate: Schema.Literals(["question_resolved"]),
  questionId: Schema.String,
  outcome: QuestionOutcome,
  questions: Schema.Array(QuestionSpec),
  answers: Schema.optional(Schema.Record(Schema.String, QuestionAnswerEntry))
})
export type QuestionResolvedPayload = typeof QuestionResolvedPayload.Type
