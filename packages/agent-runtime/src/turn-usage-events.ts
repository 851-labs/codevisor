import { Option, Schema } from "effect"

import type { RuntimeEvent } from "./types.js"

export const TURN_USAGE_UPDATE = "turn_usage_update"

export const TurnTokens = Schema.Struct({
  inputTokens: Schema.optional(Schema.Number),
  cachedInputTokens: Schema.optional(Schema.Number),
  outputTokens: Schema.optional(Schema.Number),
  reasoningOutputTokens: Schema.optional(Schema.Number),
  totalTokens: Schema.optional(Schema.Number)
})
export type TurnTokens = typeof TurnTokens.Type

const decodeTurnUsage = Schema.decodeUnknownOption(
  Schema.Struct({ sessionUpdate: Schema.Literal(TURN_USAGE_UPDATE), tokens: TurnTokens })
)

export const turnUsageObserved = (subjectId: string, tokens: TurnTokens): RuntimeEvent => ({
  kind: "session.updated",
  subjectId,
  payload: { sessionUpdate: TURN_USAGE_UPDATE, tokens }
})

export const turnUsageOf = (payload: unknown): TurnTokens | undefined =>
  Option.getOrUndefined(Option.map(decodeTurnUsage(payload), (decoded) => decoded.tokens))
