import { join } from "node:path"
import { fileURLToPath } from "node:url"

import type { AgentSessionSummary } from "@codevisor/agent-runtime"

import { finite, text } from "./protocol.js"

export type SummaryReader = (path: string) => Promise<ReadonlyArray<Record<string, unknown>>>

export const summariesPath = (geminiDir: string): string =>
  join(geminiDir, "antigravity-cli", "conversation_summaries.db")

const workspace = (value: unknown): string | undefined => {
  const raw = text(value)
  if (raw === undefined) return undefined
  let entries: Array<unknown>
  try {
    const parsed: unknown = JSON.parse(raw)
    entries = Array.isArray(parsed) ? parsed : [parsed]
  } catch {
    entries = raw.split(",")
  }
  for (const entry of entries) {
    const candidate = text(entry)?.trim()
    if (candidate === undefined) continue
    if (candidate.startsWith("file://")) {
      try {
        return fileURLToPath(candidate)
      } catch {
        continue
      }
    }
    if (candidate.startsWith("/")) return candidate
  }
  return undefined
}

const timestamp = (value: unknown): string | undefined => {
  const number = finite(value) ?? (typeof value === "string" ? Number(value) : Number.NaN)
  const millis = Number.isFinite(number)
    ? number < 1e12
      ? number * 1000
      : number
    : typeof value === "string"
      ? Date.parse(value)
      : Number.NaN
  return Number.isFinite(millis) ? new Date(millis).toISOString() : undefined
}

export const agySessionSummaries = (
  rows: ReadonlyArray<Record<string, unknown>>
): Array<AgentSessionSummary> =>
  rows.flatMap((row): Array<AgentSessionSummary> => {
    const sessionId = text(row.conversation_id)
    const cwd = workspace(row.workspace_uris)
    const updatedAt = timestamp(row.last_modified_time)
    const nested =
      text(row.parent_conversation_id) !== undefined || (finite(row.nesting_depth) ?? 0) > 0
    if (sessionId === undefined || cwd === undefined || updatedAt === undefined || nested) return []
    const title = text(row.title)?.trim() || text(row.preview)?.trim()
    return [{ sessionId, cwd, updatedAt, ...(title ? { title } : {}) }]
  })

/* v8 ignore start */
export const readSummaries: SummaryReader = async (path) => {
  const { default: Database } = await import("better-sqlite3")
  let database: InstanceType<typeof Database>
  try {
    database = new Database(path, { readonly: true, fileMustExist: true })
  } catch {
    return []
  }
  try {
    return database
      .prepare("SELECT * FROM conversation_summaries ORDER BY last_modified_time DESC LIMIT 500")
      .all() as Array<Record<string, unknown>>
  } catch {
    return []
  } finally {
    database.close()
  }
}
/* v8 ignore stop */
