import { PromptAttribution } from "@codevisor/api"
import { Schema } from "effect"

export const attributionFrom = (value: unknown): PromptAttribution | undefined => {
  if (value === undefined) return undefined
  try {
    return Schema.decodeUnknownSync(PromptAttribution)(value)
  } catch {
    return undefined
  }
}

export const parseAttribution = (raw: string | null | undefined): PromptAttribution | undefined => {
  if (raw === null || raw === undefined) return undefined
  try {
    return attributionFrom(JSON.parse(raw))
  } catch {
    return undefined
  }
}

export const serializeAttribution = (attribution: PromptAttribution | undefined): string | null =>
  attribution === undefined ? null : JSON.stringify(attribution)
