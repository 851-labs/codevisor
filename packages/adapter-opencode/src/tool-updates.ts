import { isAbsolute, resolve } from "node:path"

import { record, type JsonRecord } from "./internal.js"

export interface ToolCallState {
  readonly toolCallId: string
  readonly toolName: string
  readonly input: JsonRecord
  readonly cwd: string
}

const V1_ALIASES = new Map([
  ["bash", "shell"],
  ["task", "subagent"],
  ["apply_patch", "patch"]
])

export const canonicalToolName = (toolName: string): string => {
  const name = toolName.toLocaleLowerCase()
  return V1_ALIASES.get(name) ?? name
}

const SEARCH_TOOLS = new Set([
  "grep",
  "glob",
  "context",
  "context7_resolve_library_id",
  "context7_get_library_docs"
])

const toolKind = (toolName: string): string => {
  const name = canonicalToolName(toolName)
  if (name === "shell") return "execute"
  if (name === "webfetch") return "fetch"
  if (name === "edit" || name === "patch" || name === "write") return "edit"
  if (SEARCH_TOOLS.has(name)) return "search"
  if (name === "read") return "read"
  if (name === "subagent") return "think"
  return "other"
}

export const stringValue = (value: unknown): string | undefined =>
  typeof value === "string" ? value : undefined

export const filePath = (input: JsonRecord): string | undefined =>
  stringValue(input.path) ?? stringValue(input.filePath)

export const absolutePath = (path: string, cwd: string): string =>
  isAbsolute(path) ? path : resolve(cwd, path)

const PATCH_PATH = /^\*\*\* (?:Add|Update|Delete) File: (.+)$|^\*\*\* Move to: (.+)$/

const patchPaths = (input: JsonRecord): ReadonlyArray<string> =>
  (stringValue(input.patchText) ?? "").split("\n").flatMap((line) => {
    const match = PATCH_PATH.exec(line.trim())
    const path = match?.[1] ?? match?.[2]
    return path === undefined ? [] : [path.trim()]
  })

const locationsFrom = (cwd: string, values: ReadonlyArray<unknown>) =>
  Array.from(
    new Set(
      values.flatMap((value) =>
        typeof value === "string" && value !== "" ? [absolutePath(value, cwd)] : []
      )
    ),
    (path) => ({ path })
  )

export const toolLocations = (
  toolName: string,
  input: JsonRecord,
  cwd: string
): ReadonlyArray<{ readonly path: string }> => {
  const name = canonicalToolName(toolName)
  if (name === "shell")
    return locationsFrom(cwd, [stringValue(input.workdir) ?? stringValue(input.cwd) ?? cwd])
  if (name === "read" || name === "edit" || name === "write")
    return locationsFrom(cwd, [filePath(input)])
  if (name === "patch") return locationsFrom(cwd, patchPaths(input))
  if (name === "external_directory") return locationsFrom(cwd, [input.filepath])
  if (SEARCH_TOOLS.has(name)) return locationsFrom(cwd, [input.path])
  return []
}

const isShell = (toolName: string) => canonicalToolName(toolName) === "shell"

export const toolTitle = (toolName: string, input: JsonRecord, fallback?: string): string => {
  if (isShell(toolName))
    return stringValue(input.command) ?? stringValue(input.cmd) ?? fallback ?? toolName
  return fallback === undefined || fallback === "" ? toolName : fallback
}

const rawInput = (toolName: string, input: JsonRecord, cwd: string): JsonRecord =>
  !isShell(toolName) || input.cwd !== undefined || input.workdir !== undefined
    ? input
    : { ...input, cwd }

export const pendingToolCall = (state: ToolCallState, title?: string): JsonRecord => ({
  toolCallId: state.toolCallId,
  name: state.toolName,
  title: toolTitle(state.toolName, state.input, title),
  kind: toolKind(state.toolName),
  status: "pending",
  locations: toolLocations(state.toolName, state.input, state.cwd),
  rawInput: rawInput(state.toolName, state.input, state.cwd)
})

export const runningToolUpdate = (state: ToolCallState): JsonRecord => ({
  toolCallId: state.toolCallId,
  status: "in_progress",
  kind: toolKind(state.toolName),
  title: toolTitle(state.toolName, state.input),
  locations: toolLocations(state.toolName, state.input, state.cwd),
  rawInput: rawInput(state.toolName, state.input, state.cwd)
})

const DATA_IMAGE = /^data:([^;,]+)(?:;[^,]*)*;base64,(.*)$/

const toolContent = (content: ReadonlyArray<unknown>): Array<JsonRecord> =>
  content.flatMap((value): Array<JsonRecord> => {
    const part = record(value)
    if (part?.type === "text" && typeof part.text === "string")
      return [{ type: "content", content: { type: "text", text: part.text } }]
    const match = DATA_IMAGE.exec(stringValue(part?.uri) ?? "")
    if (match?.[1]?.startsWith("image/") !== true || match[2] === undefined) return []
    return [{ type: "content", content: { type: "image", mimeType: match[1], data: match[2] } }]
  })

export const readDisplayText = (text: string): string | undefined => {
  if (!text.startsWith("{")) return undefined
  let envelope: JsonRecord | undefined
  try {
    envelope = record(JSON.parse(text))
  } catch {
    return undefined
  }
  if (
    typeof envelope?.content === "string" &&
    (envelope.type === "text-page" || envelope.encoding === "utf8")
  )
    return envelope.content
  if (!Array.isArray(envelope?.entries)) return undefined
  return envelope.entries
    .flatMap((entry: unknown) => {
      if (typeof entry === "string") return [entry]
      const path = record(entry)?.path
      return typeof path === "string" ? [path] : []
    })
    .join("\n")
}

const isImage = (part: JsonRecord) => record(part.content)?.type === "image"

export const completedToolUpdate = (
  state: ToolCallState,
  content: ReadonlyArray<unknown>,
  metadata: JsonRecord | undefined
): JsonRecord => {
  const normalized = toolContent(content)
  const firstText = content.map(record).find((part) => part?.type === "text")
  const read =
    canonicalToolName(state.toolName) === "read" && typeof firstText?.text === "string"
      ? readDisplayText(firstText.text)
      : undefined
  const images = normalized.filter(isImage)
  const primary =
    read === undefined
      ? normalized.filter((part) => !isImage(part))
      : [{ type: "content", content: { type: "text", text: read } }]
  return {
    toolCallId: state.toolCallId,
    status: "completed",
    locations: toolLocations(state.toolName, state.input, state.cwd),
    content: [...primary, ...images],
    rawOutput: metadata === undefined ? {} : { metadata }
  }
}

export const failedToolUpdate = (
  state: ToolCallState,
  content: ReadonlyArray<unknown>,
  metadata: JsonRecord | undefined,
  error: string
): JsonRecord => ({
  toolCallId: state.toolCallId,
  status: "failed",
  kind: toolKind(state.toolName),
  title: toolTitle(state.toolName, state.input),
  locations: toolLocations(state.toolName, state.input, state.cwd),
  rawInput: rawInput(state.toolName, state.input, state.cwd),
  content: [...toolContent(content), { type: "content", content: { type: "text", text: error } }],
  rawOutput: { ...(metadata === undefined ? {} : { metadata }), error }
})
