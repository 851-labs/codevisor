import { Schema } from "effect"

export const ActionRequiredKind = Schema.Literals(["question", "approval", "planApproval"])
export type ActionRequiredKind = typeof ActionRequiredKind.Type

export const TurnFailure = Schema.Literals(["error", "usageLimit"])
export type TurnFailure = typeof TurnFailure.Type
