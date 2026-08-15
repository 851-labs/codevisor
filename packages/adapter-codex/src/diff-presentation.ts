import type { DiffStat } from "@codevisor/api"
import { diffStatsFromUnified, lineCount } from "@codevisor/agent-runtime"
import { isRecord } from "./internal.js"

/// For adds/deletes codex sends the raw file content in `diff`, not a unified
/// diff — every line counts. Updates carry a real unified diff body.
export const fileChangeStats = (changes: unknown): Array<DiffStat> => {
  if (!Array.isArray(changes)) return []
  return changes.flatMap((change) => {
    if (!isRecord(change)) return []
    const path = typeof change.path === "string" ? change.path : undefined
    const diff = typeof change.diff === "string" ? change.diff : undefined
    if (path === undefined || diff === undefined) return []
    switch (changeKind(change)) {
      case "add":
        return [{ added: lineCount(diff), path, removed: 0 }]
      case "delete":
        return [{ added: 0, path, removed: lineCount(diff) }]
      default:
        return [diffStatsFromUnified(path, diff)]
    }
  })
}

const changeKind = (change: Record<string, unknown>): string => {
  const kind = change.kind
  if (isRecord(kind) && typeof kind.type === "string") return kind.type
  return typeof kind === "string" ? kind : "update"
}

export const fileChangeDiffBlocks = (
  changes: unknown
): Array<{ type: "diff"; path: string; oldText: string | null; newText: string }> => {
  if (!Array.isArray(changes)) return []
  return changes.flatMap((change) => {
    if (!isRecord(change)) return []
    const path = typeof change.path === "string" ? change.path : undefined
    const diff = typeof change.diff === "string" ? change.diff : undefined
    if (path === undefined || diff === undefined) return []
    switch (changeKind(change)) {
      case "add":
        return [{ newText: diff, oldText: null, path, type: "diff" as const }]
      case "delete":
        return [{ newText: "", oldText: diff, path, type: "diff" as const }]
      default: {
        const texts = textsFromUnified(diff)
        if (texts === undefined) return []
        return [{ newText: texts.newText, oldText: texts.oldText, path, type: "diff" as const }]
      }
    }
  })
}

/// Reconstructs old/new text from a unified diff body so the client's DiffView
/// can render it. Hunk headers reset nothing here — the reconstruction is a
/// display approximation covering the changed regions and their context.
const textsFromUnified = (
  diff: string
): { oldText: string | null; newText: string } | undefined => {
  const oldLines: Array<string> = []
  const newLines: Array<string> = []
  let sawContent = false
  for (const line of diff.split("\n")) {
    if (line.startsWith("+++") || line.startsWith("---") || line.startsWith("@@")) continue
    if (line.startsWith("+")) {
      newLines.push(line.slice(1))
      sawContent = true
    } else if (line.startsWith("-")) {
      oldLines.push(line.slice(1))
      sawContent = true
    } else {
      const text = line.startsWith(" ") ? line.slice(1) : line
      oldLines.push(text)
      newLines.push(text)
    }
  }
  if (!sawContent) return undefined
  return {
    newText: `${newLines.join("\n")}\n`,
    oldText: oldLines.length === 0 ? null : `${oldLines.join("\n")}\n`
  }
}

export const fileChangeTitle = (changes: unknown, done: boolean): string => {
  const verb = done ? "Edited" : "Editing"
  if (Array.isArray(changes)) {
    const paths = changes.flatMap((change) =>
      isRecord(change) && typeof change.path === "string" ? [change.path] : []
    )
    const first = paths[0]?.split("/").at(-1)
    if (first !== undefined) {
      return paths.length > 1 ? `${verb} ${first} +${paths.length - 1} more` : `${verb} ${first}`
    }
  }
  return done ? "Edited files" : "Editing files"
}

export const commandStatus = (item: Record<string, unknown>): string => {
  switch (item.status) {
    case "completed":
      return typeof item.exitCode === "number" && item.exitCode !== 0 ? "failed" : "completed"
    case "failed":
      return "failed"
    case "declined":
      return "cancelled"
    default:
      return "completed"
  }
}

export const patchStatus = (item: Record<string, unknown>): string => {
  switch (item.status) {
    case "failed":
      return "failed"
    case "declined":
      return "cancelled"
    default:
      return "completed"
  }
}

export const planStatus = (status: unknown): string => {
  switch (status) {
    case "inProgress":
    case "in_progress":
      return "in_progress"
    case "completed":
      return "completed"
    default:
      return "pending"
  }
}
