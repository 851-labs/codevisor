import { Schema } from "effect"

import { Labels } from "./labels.js"
import { SandboxState } from "./sandboxes.js"
import { QuestionPayload } from "./session-updates.js"

export const AgentState = Schema.Literals(["working", "waitingForUser", "idle", "errored"])
export type AgentState = typeof AgentState.Type

export const AgentStatus = Schema.Struct({
  agentId: Schema.String,
  title: Schema.String,
  state: AgentState,
  lastReply: Schema.optional(Schema.String),
  pendingQuestion: Schema.optional(QuestionPayload)
})
export type AgentStatus = typeof AgentStatus.Type

export const AgentItemKind = Schema.Literals(["user", "assistant", "tool", "event"])
export type AgentItemKind = typeof AgentItemKind.Type

export const AgentSearchHit = Schema.Struct({
  itemId: Schema.String,
  kind: AgentItemKind,
  tool: Schema.optional(Schema.String),
  at: Schema.String,
  snippet: Schema.String
})
export type AgentSearchHit = typeof AgentSearchHit.Type

export const AgentSearchResult = Schema.Struct({
  items: Schema.Array(AgentSearchHit),
  next: Schema.optional(Schema.String)
})
export type AgentSearchResult = typeof AgentSearchResult.Type

export const AgentItem = Schema.Struct({
  itemId: Schema.String,
  kind: AgentItemKind,
  at: Schema.optional(Schema.String),
  text: Schema.optional(Schema.String),
  tool: Schema.optional(Schema.String),
  status: Schema.optional(Schema.String),
  input: Schema.optional(Schema.Unknown),
  output: Schema.optional(Schema.Unknown)
})
export type AgentItem = typeof AgentItem.Type

export const AgentSummary = Schema.Struct({
  agentId: Schema.String,
  title: Schema.String,
  state: AgentState,
  projectId: Schema.String,
  harness: Schema.String,
  workspaceId: Schema.optional(Schema.String),
  worktreeName: Schema.optional(Schema.String),
  labels: Schema.optional(Labels),
  parentAgentId: Schema.optional(Schema.String),
  updatedAt: Schema.optional(Schema.String)
})
export type AgentSummary = typeof AgentSummary.Type

export const AgentList = Schema.Struct({ items: Schema.Array(AgentSummary) })
export type AgentList = typeof AgentList.Type

export const WaitForAgentsRequest = Schema.Struct({
  agentIds: Schema.Array(Schema.String),
  until: Schema.optional(Schema.Array(AgentState)),
  timeoutMs: Schema.optional(Schema.Number)
})
export type WaitForAgentsRequest = typeof WaitForAgentsRequest.Type

export const WaitedAgent = Schema.Struct({
  agentId: Schema.String,
  state: AgentState,
  pendingQuestion: Schema.optional(QuestionPayload)
})
export type WaitedAgent = typeof WaitedAgent.Type

export const WaitForAgentsResponse = Schema.Struct({
  items: Schema.Array(WaitedAgent),
  timedOut: Schema.Boolean
})
export type WaitForAgentsResponse = typeof WaitForAgentsResponse.Type

export const CloseAgentRequest = Schema.Struct({ callerAgentId: Schema.String })
export type CloseAgentRequest = typeof CloseAgentRequest.Type

export const ClosedAgent = Schema.Struct({
  agentId: Schema.String,
  workspaceId: Schema.String,
  closed: Schema.Literal(true)
})
export type ClosedAgent = typeof ClosedAgent.Type

export const AgentIsolation = Schema.Literals(["worktree", "shared", "project"])
export type AgentIsolation = typeof AgentIsolation.Type

export const AgentProjectSource = Schema.Struct({
  name: Schema.String,
  repoUrl: Schema.String
})
export type AgentProjectSource = typeof AgentProjectSource.Type

export const AgentCallerDefaults = Schema.Struct({
  harness: Schema.String,
  configSelections: Schema.optional(Schema.Record(Schema.String, Schema.String)),
  project: Schema.optional(AgentProjectSource)
})
export type AgentCallerDefaults = typeof AgentCallerDefaults.Type

export const StartAgentRequest = Schema.Struct({
  prompt: Schema.String,
  title: Schema.String,
  isolation: AgentIsolation,
  harness: Schema.optional(Schema.String),
  model: Schema.optional(Schema.String),
  project: Schema.optional(Schema.String),
  labels: Schema.optional(Labels),
  callerAgentId: Schema.optional(Schema.String),
  remoteParentAgentId: Schema.optional(Schema.String),
  callerDefaults: Schema.optional(AgentCallerDefaults),
  sandboxProfile: Schema.optional(Schema.String)
})
export type StartAgentRequest = typeof StartAgentRequest.Type

export const StartedAgent = Schema.Struct({
  agentId: Schema.String,
  title: Schema.String,
  projectId: Schema.String,
  workspaceId: Schema.optional(Schema.String),
  worktreeName: Schema.optional(Schema.String),
  delivered: Schema.optional(Schema.String),
  subscribed: Schema.Boolean
})
export type StartedAgent = typeof StartedAgent.Type

export const StartedSandboxAgent = Schema.Struct({
  sandboxId: Schema.String,
  title: Schema.String,
  projectId: Schema.String,
  profileId: Schema.String,
  state: SandboxState
})
export type StartedSandboxAgent = typeof StartedSandboxAgent.Type
