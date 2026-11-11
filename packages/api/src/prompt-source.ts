import { Schema } from "effect"

import type { AgentRef } from "./agent-references.js"

export const PromptAttribution = Schema.Struct({
  kind: Schema.Literal("app"),
  viewId: Schema.String,
  plugin: Schema.String
})
export type PromptAttribution = typeof PromptAttribution.Type

export interface PromptSource {
  readonly attribution?: PromptAttribution | undefined
  readonly sentByAgent?: AgentRef | undefined
}
