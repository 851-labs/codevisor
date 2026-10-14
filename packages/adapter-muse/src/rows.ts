import type { EventKind } from "@codevisor/api"

import { record } from "./protocol.js"

export interface MappedEvent {
  readonly kind: EventKind
  readonly payload: Record<string, unknown>
}

export type Edge = "started" | "updated" | "completed"

export const output = (payload: Record<string, unknown>): MappedEvent => ({
  kind: "session.output",
  payload
})

export const parseArgs = (args: string | undefined): Record<string, unknown> => {
  if (args === undefined) return {}
  try {
    return record(JSON.parse(args))
  } catch {
    return {}
  }
}

export const toolStatus = (status: string): string => {
  switch (status) {
    case "inProgress":
      return "in_progress"
    case "completed":
      return "completed"
    default:
      return "failed"
  }
}

export const textContent = (value: string | undefined) =>
  value === undefined ? [] : [{ type: "content", content: { type: "text", text: value } }]
