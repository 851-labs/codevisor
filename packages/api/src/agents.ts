import { Schema } from "effect"

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
