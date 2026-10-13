import type { EventKind } from "@codevisor/api"

import { record } from "./protocol.js"

/// What every item mapper builds on: transcript events and the row
/// statuses and contents they carry.

export interface MappedEvent {
  readonly kind: EventKind
  readonly payload: Record<string, unknown>
}

export type Edge = "started" | "updated" | "completed"

export const output = (payload: Record<string, unknown>): MappedEvent => ({
  kind: "session.output",
  payload
})

/// A tool's JSON arguments (or JSON result), as an object.
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
