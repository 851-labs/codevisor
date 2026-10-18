import { HarnessUsageLimits } from "@codevisor/api"
import { Option, Schema } from "effect"

import type { RuntimeEvent } from "./types.js"

export const USAGE_LIMITS_UPDATE = "usage_limits_update"

export interface UsageLimitsObservation {
  readonly limits: HarnessUsageLimits
  readonly partial: boolean
}

const decodeObservation = Schema.decodeUnknownOption(
  Schema.Struct({
    sessionUpdate: Schema.Literal(USAGE_LIMITS_UPDATE),
    limits: HarnessUsageLimits,
    partial: Schema.optional(Schema.Boolean)
  })
)

export const usageLimitsObserved = (
  subjectId: string,
  limits: HarnessUsageLimits,
  partial = false
): RuntimeEvent => ({
  kind: "session.updated",
  subjectId,
  payload: { sessionUpdate: USAGE_LIMITS_UPDATE, limits, partial }
})

export const usageLimitsObservation = (payload: unknown): UsageLimitsObservation | undefined =>
  Option.getOrUndefined(
    Option.map(decodeObservation(payload), (decoded) => ({
      limits: decoded.limits,
      partial: decoded.partial === true
    }))
  )
