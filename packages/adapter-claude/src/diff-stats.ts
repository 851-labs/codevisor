import { isAbsolute, resolve } from "node:path"

import { diffStatsFromTexts, lineCount } from "@codevisor/agent-runtime"
import type { DiffStat } from "@codevisor/api"

import { isRecord } from "./internal.js"
import { extractAllStringFields, extractStringField } from "./partial-json-string.js"
import type { ClaudeSession, ToolInputAccumulator } from "./session.js"
import { activeToolTitle } from "./tool-presentation.js"

const STREAM_STATS_INTERVAL_MS = 250

const EDIT_TOOLS = new Set(["Edit", "Write", "MultiEdit", "NotebookEdit"])

export const maybeEmitStreamStats = (
  session: ClaudeSession,
  toolUseId: string,
  accumulator: ToolInputAccumulator,
  readFile: (path: string) => string | undefined,
  force: boolean
): void => {
  if (!EDIT_TOOLS.has(accumulator.toolName)) return
  const now = Date.now()
  if (!force && now - accumulator.lastEmit < STREAM_STATS_INTERVAL_MS) return
  const stats = streamingStats(session, accumulator, readFile)
  if (stats === undefined) return
  const fingerprint = JSON.stringify(stats)
  if (fingerprint === accumulator.lastStats) return
  accumulator.lastEmit = now
  accumulator.lastStats = fingerprint
  const path = stats[0]?.path
  const title =
    path !== undefined && accumulator.titledPath !== path
      ? activeToolTitle(accumulator.toolName, path)
      : undefined
  if (path !== undefined) {
    accumulator.titledPath = path
  }
  void session.emit({
    kind: "session.output",
    payload: {
      diffStats: stats,
      sessionUpdate: "tool_call_update",
      status: "in_progress",
      toolCallId: toolUseId,
      ...(title === undefined ? {} : { title })
    },
    subjectId: session.key
  })
}

const streamingStats = (
  session: ClaudeSession,
  accumulator: ToolInputAccumulator,
  readFile: (path: string) => string | undefined
): Array<DiffStat> | undefined => {
  const path = extractStringField(accumulator.json, "file_path")
  if (path === undefined || path.length === 0) return undefined
  switch (accumulator.toolName) {
    case "Edit": {
      const oldString = extractStringField(accumulator.json, "old_string") ?? ""
      const newString = extractStringField(accumulator.json, "new_string") ?? ""
      return [{ added: lineCount(newString), path, removed: lineCount(oldString) }]
    }
    case "Write": {
      if (accumulator.oldContent === undefined) {
        accumulator.oldContent = readFile(absolutePath(session.cwd, path)) ?? null
      }
      const content = extractStringField(accumulator.json, "content") ?? ""
      return [
        {
          added: lineCount(content),
          path,
          removed: accumulator.oldContent === null ? 0 : lineCount(accumulator.oldContent)
        }
      ]
    }
    case "MultiEdit": {
      const oldStrings = extractAllStringFields(accumulator.json, "old_string")
      const newStrings = extractAllStringFields(accumulator.json, "new_string")
      return [
        {
          added: newStrings.reduce((total, text) => total + lineCount(text), 0),
          path,
          removed: oldStrings.reduce((total, text) => total + lineCount(text), 0)
        }
      ]
    }
    default:
      return undefined
  }
}

export const authoritativeStatsFromInput = (
  session: ClaudeSession,
  toolName: string,
  input: unknown,
  readFile: (path: string) => string | undefined
): Array<DiffStat> | undefined => {
  if (!EDIT_TOOLS.has(toolName) || !isRecord(input)) return undefined
  const path = typeof input.file_path === "string" ? input.file_path : undefined
  if (path === undefined) return undefined
  switch (toolName) {
    case "Edit": {
      const oldString = typeof input.old_string === "string" ? input.old_string : ""
      const newString = typeof input.new_string === "string" ? input.new_string : ""
      return [diffStatsFromTexts(path, oldString, newString)]
    }
    case "Write": {
      const content = typeof input.content === "string" ? input.content : ""
      const oldContent = readFile(absolutePath(session.cwd, path))
      return [diffStatsFromTexts(path, oldContent, content)]
    }
    case "MultiEdit": {
      const edits = Array.isArray(input.edits) ? input.edits : []
      let added = 0
      let removed = 0
      for (const edit of edits) {
        if (!isRecord(edit)) continue
        const stats = diffStatsFromTexts(
          path,
          typeof edit.old_string === "string" ? edit.old_string : "",
          typeof edit.new_string === "string" ? edit.new_string : ""
        )
        added += stats.added
        removed += stats.removed
      }
      return [{ added, path, removed }]
    }
    default:
      return undefined
  }
}

const structuredPatchStats = (
  response: Record<string, unknown>,
  path: string
): DiffStat | undefined => {
  if (!Array.isArray(response.structuredPatch)) return undefined
  let added = 0
  let removed = 0
  for (const hunk of response.structuredPatch) {
    if (!isRecord(hunk) || !Array.isArray(hunk.lines)) continue
    for (const line of hunk.lines) {
      if (typeof line !== "string") continue
      if (line.startsWith("+")) added += 1
      else if (line.startsWith("-")) removed += 1
    }
  }
  return { added, path, removed }
}

const authoritativeDiffPayload = (
  toolCallId: string,
  stats: DiffStat | undefined,
  diffBlock: ReturnType<typeof diffContentBlock>,
  path: string
): Record<string, unknown> => {
  const payload: Record<string, unknown> = { sessionUpdate: "tool_call_update", toolCallId }
  if (stats !== undefined) payload.diffStats = [stats]
  if (diffBlock !== undefined) payload.content = [diffBlock]
  if (stats === undefined && diffBlock !== undefined) {
    payload.diffStats = [diffStatsFromTexts(path, diffBlock.oldText, diffBlock.newText)]
  }
  return payload
}

export const emitAuthoritativeDiff = (
  session: ClaudeSession,
  hookInput: {
    tool_name: string
    tool_input: unknown
    tool_response: unknown
    tool_use_id: string
  }
): void => {
  if (!EDIT_TOOLS.has(hookInput.tool_name)) return
  const input = isRecord(hookInput.tool_input) ? hookInput.tool_input : {}
  const path = typeof input.file_path === "string" ? input.file_path : undefined
  if (path === undefined) return

  const response = isRecord(hookInput.tool_response) ? hookInput.tool_response : {}
  let stats = structuredPatchStats(response, path)

  const diffBlock = diffContentBlock(hookInput.tool_name, input, response, path)
  if (
    stats !== undefined &&
    stats.added === 0 &&
    stats.removed === 0 &&
    diffBlock !== undefined &&
    (diffBlock.oldText ?? "") !== diffBlock.newText
  ) {
    stats = diffStatsFromTexts(path, diffBlock.oldText, diffBlock.newText)
  }
  if (stats === undefined && diffBlock === undefined) return
  void session.emit({
    kind: "session.output",
    payload: authoritativeDiffPayload(hookInput.tool_use_id, stats, diffBlock, path),
    subjectId: session.key
  })
}

const diffContentBlock = (
  toolName: string,
  input: Record<string, unknown>,
  response: Record<string, unknown>,
  path: string
): { type: "diff"; path: string; oldText: string | null; newText: string } | undefined => {
  switch (toolName) {
    case "Edit": {
      const oldString = typeof input.old_string === "string" ? input.old_string : null
      const newString = typeof input.new_string === "string" ? input.new_string : ""
      return { newText: newString, oldText: oldString, path, type: "diff" }
    }
    case "Write": {
      const content = typeof input.content === "string" ? input.content : ""
      const original = typeof response.originalFile === "string" ? response.originalFile : null
      return { newText: content, oldText: original, path, type: "diff" }
    }
    default:
      return undefined
  }
}

const absolutePath = (cwd: string, path: string): string =>
  isAbsolute(path) ? path : resolve(cwd, path)
