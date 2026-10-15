import type { BrowserRuntime } from "./browser-cdp-engine.js"
import { recordOrEmpty, recordsIn, type UnknownRecord } from "./unknown-values.js"

type Entry = UnknownRecord

const primitiveText = (value: unknown): string | undefined =>
  typeof value === "string" || typeof value === "number" || typeof value === "boolean"
    ? String(value)
    : undefined

interface BrowserLogEntry {
  readonly level: string
  readonly message: string
  readonly timestamp: string
  readonly url?: string
}

function consoleMessage(entry: Entry): string {
  return recordsIn(entry.args)
    .map(
      (value) =>
        primitiveText(value.value) ??
        primitiveText(value.description) ??
        primitiveText(value.type) ??
        ""
    )
    .join(" ")
}

function consoleEntry(entry: Entry): BrowserLogEntry {
  const message = consoleMessage(entry)
  return {
    level: entry.type === "warning" ? "warn" : (primitiveText(entry.type) ?? "log"),
    message,
    timestamp: new Date(Number(entry.timestamp ?? Date.now())).toISOString()
  }
}

function logEntry(entry: Entry): BrowserLogEntry {
  const value = recordOrEmpty(entry.entry)
  return {
    level: value.level === "warning" ? "warn" : (primitiveText(value.level) ?? "log"),
    message: primitiveText(value.text) ?? "",
    timestamp: new Date(Number(value.timestamp ?? Date.now())).toISOString(),
    ...(typeof value.url === "string" ? { url: value.url } : {})
  }
}

function exceptionEntry(entry: Entry): BrowserLogEntry {
  const detail = recordOrEmpty(entry.exceptionDetails)
  const exception = recordOrEmpty(detail.exception)
  return {
    level: "error",
    message:
      primitiveText(exception.description) ?? primitiveText(detail.text) ?? "Uncaught page error",
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
  const normalized = (logs.get(sessionId) ?? []).map(normalizeEntry)
  return normalized
    .filter(
      (entry) =>
        (levels === undefined || levels.has(entry.level)) &&
        (filter === undefined || entry.message.includes(filter))
    )
    .slice(-Math.max(1, Math.min(1_000, Number(args.limit ?? 100))))
}
