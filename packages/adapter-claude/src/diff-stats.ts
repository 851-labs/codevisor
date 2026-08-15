import type { DiffStat } from "@codevisor/api"
import { diffStatsFromTexts, lineCount } from "@codevisor/agent-runtime"
import { isAbsolute, resolve } from "node:path"
import { isRecord } from "./internal.js"
import type { ClaudeSession, ToolInputAccumulator } from "./session.js"
import { activeToolTitle } from "./tool-presentation.js"

/// Streaming diff-stat updates are throttled per tool call; every event is
/// persisted server-side, so unbounded input_json_delta emission would bloat
/// the events table.
const STREAM_STATS_INTERVAL_MS = 250

// MARK: diff stats

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

/// Running estimate computed from the partially streamed tool input. Counts
/// only ever grow as the strings stream in; the consolidated input and the
/// PostToolUse hook later replace them with authoritative numbers.
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

/// Authoritative stats from the consolidated (fully parsed) tool input.
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

/// PostToolUse delivers the on-disk truth (structuredPatch reflects
/// replace_all and the file's actual state); emit the final stats plus a
/// renderable diff content block.
export const emitAuthoritativeDiff = (
  session: ClaudeSession,
  hookInput: {
    tool_name: string
    tool_input: unknown
    tool_response: unknown
    tool_use_id: string
  },
  readFile: (path: string) => string | undefined
): void => {
  if (!EDIT_TOOLS.has(hookInput.tool_name)) return
  const input = isRecord(hookInput.tool_input) ? hookInput.tool_input : {}
  const path = typeof input.file_path === "string" ? input.file_path : undefined
  if (path === undefined) return

  const response = isRecord(hookInput.tool_response) ? hookInput.tool_response : {}
  let stats: DiffStat | undefined
  if (Array.isArray(response.structuredPatch)) {
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
    stats = { added, path, removed }
  }

  const diffBlock = diffContentBlock(session, hookInput.tool_name, input, response, path, readFile)
  // A file creation's tool_response carries an empty structuredPatch (there
  // was nothing to patch — the whole file is new), which would report an
  // authoritative +0 −0 that beats the client's content-derived totals. When
  // the diff content shows a real change, recompute the stats from the texts.
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
    payload: {
      sessionUpdate: "tool_call_update",
      toolCallId: hookInput.tool_use_id,
      ...(stats === undefined ? {} : { diffStats: [stats] }),
      ...(diffBlock === undefined ? {} : { content: [diffBlock] }),
      ...(stats === undefined && diffBlock !== undefined
        ? { diffStats: [diffStatsFromTexts(path, diffBlock.oldText, diffBlock.newText)] }
        : {})
    },
    subjectId: session.key
  })
}

const diffContentBlock = (
  session: ClaudeSession,
  toolName: string,
  input: Record<string, unknown>,
  response: Record<string, unknown>,
  path: string,
  readFile: (path: string) => string | undefined
): { type: "diff"; path: string; oldText: string | null; newText: string } | undefined => {
  switch (toolName) {
    case "Edit": {
      const oldString = typeof input.old_string === "string" ? input.old_string : null
      const newString = typeof input.new_string === "string" ? input.new_string : ""
      return { newText: newString, oldText: oldString, path, type: "diff" }
    }
    case "Write": {
      const content = typeof input.content === "string" ? input.content : ""
      const original =
        typeof response.originalFile === "string"
          ? response.originalFile
          : readFile(absolutePath(session.cwd, path)) === content
            ? null
            : null
      return { newText: content, oldText: original, path, type: "diff" }
    }
    default:
      return undefined
  }
}

const absolutePath = (cwd: string, path: string): string =>
  isAbsolute(path) ? path : resolve(cwd, path)

/// Extracts a JSON string field's (possibly still-streaming) value from a
/// partial JSON buffer without a full parser: finds `"field":"` and decodes
/// escapes until the closing quote or the end of the buffer.
export const extractStringField = (json: string, field: string): string | undefined => {
  const key = `"${field}"`
  let index = json.indexOf(key)
  if (index === -1) return undefined
  index += key.length
  while (index < json.length && (json[index] === " " || json[index] === ":")) index += 1
  if (json[index] !== '"') return undefined
  index += 1
  return decodeJsonString(json, index).value
}

/// Extracts every occurrence of a string field (for MultiEdit's edits array).
export const extractAllStringFields = (json: string, field: string): Array<string> => {
  const key = `"${field}"`
  const values: Array<string> = []
  let cursor = 0
  while (true) {
    let index = json.indexOf(key, cursor)
    if (index === -1) return values
    index += key.length
    while (index < json.length && (json[index] === " " || json[index] === ":")) index += 1
    if (json[index] !== '"') {
      cursor = index
      continue
    }
    index += 1
    const decoded = decodeJsonString(json, index)
    values.push(decoded.value)
    cursor = decoded.end
  }
}

const decodeJsonString = (json: string, start: number): { value: string; end: number } => {
  let out = ""
  let index = start
  while (index < json.length) {
    const ch = json[index]
    if (ch === "\\") {
      const next = json[index + 1]
      if (next === undefined) break
      switch (next) {
        case "n":
          out += "\n"
          break
        case "t":
          out += "\t"
          break
        case "r":
          out += "\r"
          break
        case '"':
          out += '"'
          break
        case "\\":
          out += "\\"
          break
        case "/":
          out += "/"
          break
        case "u": {
          const hex = json.slice(index + 2, index + 6)
          if (hex.length === 4 && /^[0-9a-fA-F]{4}$/.test(hex)) {
            out += String.fromCharCode(Number.parseInt(hex, 16))
            index += 4
          }
          break
        }
        default:
          out += next
      }
      index += 2
      continue
    }
    if (ch === '"') {
      return { end: index + 1, value: out }
    }
    out += ch
    index += 1
  }
  return { end: index, value: out }
}
