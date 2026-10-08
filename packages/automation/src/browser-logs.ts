import type { BrowserRuntime } from "./browser-cdp-engine.js"

type Entry = Readonly<Record<string, unknown>>

interface BrowserLogEntry {
  readonly level: string
  readonly message: string
  readonly timestamp: string
  readonly url?: string
}

function consoleMessage(entry: Entry): string {
  const args = Array.isArray(entry.args) ? (entry.args as Array<Entry>) : []
  return args.map((value) => String(value.value ?? value.description ?? value.type ?? "")).join(" ")
}

function consoleEntry(entry: Entry): BrowserLogEntry {
  const message = consoleMessage(entry)
  return {
    level: entry.type === "warning" ? "warn" : String(entry.type ?? "log"),
    message,
    timestamp: new Date(Number(entry.timestamp ?? Date.now())).toISOString()
  }
}

function logEntry(entry: Entry): BrowserLogEntry {
  const value =
    entry.entry !== null && typeof entry.entry === "object" ? (entry.entry as Entry) : {}
  return {
    level: value.level === "warning" ? "warn" : String(value.level ?? "log"),
    message: String(value.text ?? ""),
    timestamp: new Date(Number(value.timestamp ?? Date.now())).toISOString(),
    ...(typeof value.url === "string" ? { url: value.url } : {})
  }
}

function exceptionEntry(entry: Entry): BrowserLogEntry {
  const detail =
    entry.exceptionDetails !== null && typeof entry.exceptionDetails === "object"
      ? (entry.exceptionDetails as Entry)
      : {}
  const exception =
    detail.exception !== null && typeof detail.exception === "object"
      ? (detail.exception as Entry)
      : {}
  return {
    level: "error",
    message: String(exception.description ?? detail.text ?? "Uncaught page error"),
    timestamp: new Date(Number(entry.timestamp ?? Date.now())).toISOString(),
    ...(typeof detail.url === "string" ? { url: detail.url } : {})
  }
}

function normalizeEntry(entry: Entry): BrowserLogEntry {
  if (entry.method === "Runtime.consoleAPICalled") return consoleEntry(entry)
  if (entry.method === "Log.entryAdded") return logEntry(entry)
  return exceptionEntry(entry)
}

function readLevels(args: Entry): Set<string> | undefined {
  return Array.isArray(args.levels) && args.levels.every((level) => typeof level === "string")
    ? new Set(args.levels.map((level) => (level === "warning" ? "warn" : level)))
    : undefined
}

export function readBrowserLogs(
  logs: BrowserRuntime["logs"],
  sessionId: string,
  args: Entry
): BrowserLogEntry[] {
  const levels = readLevels(args)
  const filter = typeof args.filter === "string" ? args.filter : undefined
  // Normalize every record before filtering: even hidden invalid timestamps must throw.
  const normalized = (logs.get(sessionId) ?? []).map(normalizeEntry)
  return (
    normalized
      .filter(
        (entry) =>
          (levels === undefined || levels.has(entry.level)) &&
          (filter === undefined || entry.message.includes(filter))
      )
      // Read and coerce the limit last, retaining JavaScript's slice coercion.
      .slice(-Math.max(1, Math.min(1_000, Number(args.limit ?? 100))))
  )
}
