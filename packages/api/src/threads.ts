import { Schema } from "effect"

export const ThreadParticipant = Schema.Struct({
  kind: Schema.Literals(["bot", "agent"]),
  name: Schema.String,
  agentId: Schema.String,
  botId: Schema.optional(Schema.String),
  machineId: Schema.optional(Schema.String)
})
export type ThreadParticipant = typeof ThreadParticipant.Type

export const ThreadMessage = Schema.Struct({
  id: Schema.String,
  threadId: Schema.String,
  sequence: Schema.Number,
  from: ThreadParticipant,
  text: Schema.String,
  createdAt: Schema.String
})
export type ThreadMessage = typeof ThreadMessage.Type

export const Thread = Schema.Struct({
  threadId: Schema.String,
  participants: Schema.Array(ThreadParticipant),
  lastMessage: Schema.optional(ThreadMessage)
})
export type Thread = typeof Thread.Type

export const MessageBotRequest = Schema.Struct({
  text: Schema.String,
  sentByAgentId: Schema.optional(Schema.String),
  sentByAgentMachineId: Schema.optional(Schema.String)
})
export type MessageBotRequest = typeof MessageBotRequest.Type
