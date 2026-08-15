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
    // Not ACP vocabulary — Codevisor's own extension so clients can phrase web
    // searches as searches ("Searched the web") instead of fetches.
    case "WebSearch":
      return "web_search"
    case "TodoWrite":
      return "think"
    // The subagent-spawn tool: "Task" historically, "Agent" in newer CLIs.
    case "Task":
    case "Agent":
      return "agent"
    default:
      return "other"
  }
}

const fileNameOf = (path: string): string => path.split("/").at(-1) ?? path

/// Present-tense title while a file tool is running.
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

/// Past-tense title once the tool has finished.
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

export const toolTitle = (toolName: string, input: unknown): string => {
  if (isRecord(input)) {
    if (typeof input.file_path === "string") {
      const file = input.file_path.split("/").at(-1) ?? input.file_path
      switch (toolName) {
        case "Read":
          return `Read ${file}`
        case "Edit":
        case "MultiEdit":
          return `Edited ${file}`
        case "Write":
          return `Wrote ${file}`
        default:
          break
      }
    }
    if (toolName === "Bash" && typeof input.command === "string") {
      return `Ran ${input.command.split("\n")[0]?.slice(0, 80) ?? ""}`
    }
    if (toolName === "WebSearch" && typeof input.query === "string") {
      return `Searched for ${input.query}`
    }
    if (toolName === "WebFetch" && typeof input.url === "string") {
      return `Fetched ${input.url}`
    }
    if (typeof input.pattern === "string") {
      return `Searched for ${input.pattern}`
    }
    if ((toolName === "Task" || toolName === "Agent") && typeof input.description === "string") {
      return `Agent: ${input.description}`
    }
  }
  return toolName
}

/// A WebSearch result source (a search hit's title + URL).
export interface WebSearchSource {
  readonly title: string
  readonly url: string
}

/// Extracts the sources from a Claude WebSearch tool_result. The CLI returns a
/// string of the shape:
///   Web search results for query: "…"
///   Links: [{"title":"…","url":"…"}, …]
///   …model commentary…
/// The `Links:` array is the only structured payload; we parse it into the
/// hits so the client can render a sources list. Returns `[]` for anything
/// that isn't a web-search result, so non-search tool results never sprout a
/// bogus sources card.
export const webSearchSources = (content: unknown): Array<WebSearchSource> => {
  const text =
    typeof content === "string"
      ? content
      : Array.isArray(content)
        ? content
            .map((block) => (isRecord(block) && typeof block.text === "string" ? block.text : ""))
            .join("")
        : ""
  if (!text.includes("Web search results for query:")) return []
  const marker = text.indexOf("Links:")
  if (marker === -1) return []
  const start = text.indexOf("[", marker)
  if (start === -1) return []
  // Balanced-bracket scan that ignores brackets inside JSON strings, so the
  // array is isolated even when a title contains "[" or "]".
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

/// Maps parsed web-search sources to ACP `resource_link` tool-call content so
/// the client renders each as a titled, tappable link. Capped so a pathological
/// result can't flood the card.
export const sourcesContent = (sources: Array<WebSearchSource>): Array<Record<string, unknown>> =>
  sources.slice(0, 20).map((source) => ({
    content: { name: source.title, title: source.title, type: "resource_link", uri: source.url },
    type: "content"
  }))
