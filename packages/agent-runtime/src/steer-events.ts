import { Option, Schema } from "effect"

import type { RuntimeEvent } from "./types.js"

export const STEER_SETTLED_UPDATE = "steer_settled"

const SteerOutcomeSchema = Schema.Literals(["absorbed", "dropped"])

export type SteerOutcome = typeof SteerOutcomeSchema.Type

export interface SteerSettlement {
  readonly id: string
  readonly outcome: SteerOutcome
  readonly startsTurn: boolean
}

const decodeSettlement = Schema.decodeUnknownOption(
  Schema.Struct({
    sessionUpdate: Schema.Literal(STEER_SETTLED_UPDATE),
    steerId: Schema.String,
    outcome: SteerOutcomeSchema,
    startsTurn: Schema.optional(Schema.Boolean)
  })
)

export const steerSettlementEvent = (
  subjectId: string,
  settlement: SteerSettlement
): RuntimeEvent => ({
  kind: "session.updated",
  subjectId,
  payload: {
    sessionUpdate: STEER_SETTLED_UPDATE,
    steerId: settlement.id,
    outcome: settlement.outcome,
    startsTurn: settlement.startsTurn
  }
})

export const steerSettlementOf = (payload: unknown): SteerSettlement | undefined =>
  Option.getOrUndefined(
    Option.map(decodeSettlement(payload), (decoded) => ({
      id: decoded.steerId,
      outcome: decoded.outcome,
      startsTurn: decoded.startsTurn === true
    }))
  )
