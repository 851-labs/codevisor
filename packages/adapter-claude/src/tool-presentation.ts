import { isRecord } from "./internal.js"

export const toolKind = (toolName: string): string => {
  switch (toolName) {
    case "Read":
      return "read"
    case "Edit":
    case "Write":
    case "MultiEdit":
    case "NotebookEdit":
      return "edit"
    case "Bash":
    case "BashOutput":
    case "KillShell":
      return "execute"
    case "Grep":
    case "Glob":
      return "search"
    case "WebFetch":
      return "fetch"
    case "WebSearch":
      return "web_search"
    case "TodoWrite":
      return "think"
    case "Task":
    case "Agent":
      return "agent"
    default:
      return "other"
  }
}

const fileNameOf = (path: string): string => path.split("/").at(-1) ?? path

export const activeToolTitle = (toolName: string, path: string): string | undefined => {
  const file = fileNameOf(path)
  switch (toolName) {
    case "Edit":
    case "MultiEdit":
      return `Editing ${file}`
    case "Write":
      return `Writing ${file}`
    default:
      return undefined
  }
}

export const finishedToolTitle = (toolName: string, path: string): string | undefined => {
  const file = fileNameOf(path)
  switch (toolName) {
    case "Edit":
    case "MultiEdit":
      return `Edited ${file}`
    case "Write":
      return `Wrote ${file}`
    default:
      return undefined
  }
}

export type ToolTense = "running" | "finished"

export const toolTitle = (
  toolName: string,
  input: unknown,
  tense: ToolTense = "finished"
): string => {
  const subject = isRecord(input) ? toolSubject(toolName, input) : undefined
  if (subject === undefined) return toolName
  if (subject.verb === undefined) return subject.text
  return `${toolVerbs[subject.verb][tense]} ${subject.text}`
}

type ToolVerb = keyof typeof toolVerbs

interface ToolSubject {
  readonly verb?: ToolVerb
  readonly text: string
}

const toolVerbs = {
  read: { running: "Reading", finished: "Read" },
  edit: { running: "Editing", finished: "Edited" },
  write: { running: "Writing", finished: "Wrote" },
  run: { running: "Running", finished: "Ran" },
  search: { running: "Searching for", finished: "Searched for" },
  fetch: { running: "Fetching", finished: "Fetched" }
} as const

const fileVerbs: Readonly<Record<string, ToolVerb>> = {
  Read: "read",
  Edit: "edit",
  MultiEdit: "edit",
  Write: "write"
}

const toolSubject = (toolName: string, input: Record<string, unknown>): ToolSubject | undefined => {
  const fileVerb = fileVerbs[toolName]
  if (fileVerb !== undefined && typeof input.file_path === "string") {
    return { verb: fileVerb, text: fileNameOf(input.file_path) }
  }
  if (toolName === "Bash" && typeof input.command === "string") {
    return { verb: "run", text: input.command.split("\n")[0]?.slice(0, 80) ?? "" }
  }
  if (toolName === "WebSearch" && typeof input.query === "string") {
    return { verb: "search", text: input.query }
  }
  if (toolName === "WebFetch" && typeof input.url === "string") {
    return { verb: "fetch", text: input.url }
  }
  if (typeof input.pattern === "string") return { verb: "search", text: input.pattern }
  if ((toolName === "Task" || toolName === "Agent") && typeof input.description === "string") {
    return { text: `Agent: ${input.description}` }
  }
  return undefined
}

export interface WebSearchSource {
  readonly title: string
  readonly url: string
}

const contentText = (content: unknown): string => {
  if (typeof content === "string") return content
  if (Array.isArray(content))
    return content
      .map((block) => (isRecord(block) && typeof block.text === "string" ? block.text : ""))
      .join("")
  return ""
}

export const webSearchSources = (content: unknown): Array<WebSearchSource> => {
  const text = contentText(content)
  if (!text.includes("Web search results for query:")) return []
  const marker = text.indexOf("Links:")
  if (marker === -1) return []
  const start = text.indexOf("[", marker)
  if (start === -1) return []
  let depth = 0
  let inString = false
  let escaped = false
  let end = -1
  for (let index = start; index < text.length; index += 1) {
    const char = text[index]
    if (escaped) {
      escaped = false
      continue
    }
    if (char === "\\") {
      escaped = true
      continue
    }
    if (char === '"') {
      inString = !inString
      continue
    }
    if (inString) continue
    if (char === "[") depth += 1
    else if (char === "]") {
      depth -= 1
      if (depth === 0) {
        end = index
        break
      }
    }
  }
  if (end === -1) return []
  let parsed: unknown
  try {
    parsed = JSON.parse(text.slice(start, end + 1))
  } catch {
    return []
  }
  if (!Array.isArray(parsed)) return []
  const sources: Array<WebSearchSource> = []
  for (const hit of parsed) {
    if (isRecord(hit) && typeof hit.title === "string" && typeof hit.url === "string") {
      sources.push({ title: hit.title, url: hit.url })
    }
  }
  return sources
}

export const sourcesContent = (sources: Array<WebSearchSource>): Array<Record<string, unknown>> =>
  sources.slice(0, 20).map((source) => ({
    content: { name: source.title, title: source.title, type: "resource_link", uri: source.url },
    type: "content"
  }))
