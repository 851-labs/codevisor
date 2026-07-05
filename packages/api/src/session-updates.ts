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
  parentToolCallId: Schema.optional(Schema.String)
})
export type AgentChunkPayload = typeof AgentChunkPayload.Type

/** One in-flight background task (backgrounded shell, subagent, etc.) owned by
 *  the agent process. `toolUseId` links the task back to the tool call that
 *  spawned it, when known. */
export const BackgroundTask = Schema.Struct({
  id: Schema.String,
  description: Schema.String,
  status: Schema.String,
  taskType: Schema.String,
  toolUseId: Schema.optional(Schema.String)
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
