import { createHash } from "node:crypto"

import type { RuntimeEventSink } from "@codevisor/agent-runtime"
import {
  canonicalExecutionArgs,
  CODEVISOR_EXECUTION_MAX_CALLS,
  CODEVISOR_EXECUTION_MAX_DESCRIPTION,
  CODEVISOR_EXECUTION_MAX_ERROR,
  CODEVISOR_EXECUTION_MAX_FILES,
  CODEVISOR_EXECUTION_MAX_STATUS,
  type CodevisorExecutionCall,
  type CodevisorExecutionFile,
  type CodevisorExecutionIcon,
  type CodevisorExecutionState,
  type CodevisorSkillRead
} from "@codevisor/api"

/// Live transcript annotation for one `execute` call: the latest `status()`
/// text and every nested tool call, streamed to the session sink so the
/// server can attach them to the harness tool row. None of this reaches the
/// model's result.

export const EXECUTION_EMIT_INTERVAL_MS = 250

export interface ExecutionTimers {
  readonly now: () => number
  readonly setTimeout: (callback: () => void, ms: number) => unknown
  readonly clearTimeout: (handle: unknown) => void
}

const systemTimers: ExecutionTimers = {
  now: () => performance.now(),
  setTimeout: (callback, ms) => setTimeout(callback, ms),
  clearTimeout: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>)
}

export const truncateText = (text: string, max: number): string => {
  const collapsed = text.replace(/\s+/g, " ").trim()
  return collapsed.length <= max ? collapsed : `${collapsed.slice(0, max - 1).trimEnd()}…`
}

/// The message a person needs from a thrown error: its first line, without
/// the "Error:" prefix or the stack frames the sandbox appends.
export const errorSummary = (error: string, max: number): string => {
  const firstLine = error.split("\n").find((line) => line.trim().length > 0) ?? error
  const message = firstLine
    .replace(/^\s*(?:[A-Za-z]*Error:\s*)+/, "")
    .replace(/\s+at\s+(?:<anonymous>|[\w$.]+\s*\(|file:|node:).*$/, "")
  return truncateText(message.length > 0 ? message : firstLine, max)
}

/// sha256 hex of the canonical execute arguments, exactly as received.
export const executionArgsHash = (args: {
  readonly code: string
  readonly description: string
}): string => createHash("sha256").update(canonicalExecutionArgs(args)).digest("hex")

export interface ExecutionRecorder {
  readonly status: (text: string) => void
  readonly call: (call: CodevisorExecutionCall) => void
  /// The workflow is touching `icon` now: a call started, or a browser call
  /// left its tab on a site. The first one names the settled workflow.
  readonly touch: (icon: CodevisorExecutionIcon) => void
  /// Emits the terminal state and resolves once the sink has taken it.
  readonly finish: (error?: string) => Promise<void>
}

const sameIcon = (
  lhs: CodevisorExecutionIcon | undefined,
  rhs: CodevisorExecutionIcon | undefined
): boolean => JSON.stringify(lhs) === JSON.stringify(rhs)

const isBareBrowser = (icon: CodevisorExecutionIcon): boolean =>
  icon.kind === "builtin" && icon.id === "browser"

export const makeExecutionRecorder = (options: {
  readonly sink: RuntimeEventSink | undefined
  readonly sessionId: string
  readonly argsHash: string
  /// The workflow's label, carried for rows that can't show their own.
  readonly description?: string
  readonly timers?: ExecutionTimers
}): ExecutionRecorder => {
  const { sink, sessionId, argsHash } = options
  const timers = options.timers ?? systemTimers
  const firstLine = options.description?.split("\n").find((line) => line.trim().length > 0)
  const description =
    firstLine === undefined
      ? undefined
      : truncateText(firstLine, CODEVISOR_EXECUTION_MAX_DESCRIPTION)
  const calls: Array<CodevisorExecutionCall> = []
  let filesShown = 0
  let status: string | undefined
  let icon: CodevisorExecutionIcon | undefined
  let activeIcon: CodevisorExecutionIcon | undefined
  let lastEmitAt = Number.NEGATIVE_INFINITY
  let pending: unknown
  let finished = false
  let delivery: Promise<void> = Promise.resolve()

  const emit = (state: CodevisorExecutionState["state"], error?: string): void => {
    lastEmitAt = timers.now()
    if (sink === undefined) return
    const execution: CodevisorExecutionState = {
      state,
      ...(description === undefined ? {} : { description }),
      ...(status === undefined ? {} : { status }),
      calls: [...calls],
      ...(error === undefined ? {} : { error }),
      ...(icon === undefined ? {} : { icon }),
      ...(activeIcon === undefined ? {} : { activeIcon })
    }
    const event = {
      kind: "session.output" as const,
      subjectId: sessionId,
      payload: { kind: "codevisor_execution", argsHash, execution }
    }
    // Hand events to the sink in emission order (the session sink queues
    // them serially); an annotation failure never fails the script.
    let delivered: Promise<unknown>
    try {
      delivered = Promise.resolve(sink(event))
    } catch (cause) {
      delivered = Promise.reject(cause)
    }
    const previous = delivery
    delivery = Promise.all([previous, delivered]).then(
      () => undefined,
      () => undefined
    )
  }

  const scheduleRunning = (): void => {
    if (finished || pending !== undefined) return
    const wait = lastEmitAt + EXECUTION_EMIT_INTERVAL_MS - timers.now()
    if (wait <= 0) {
      emit("running")
      return
    }
    // finish() cancels this timer, so it only fires mid-execution.
    pending = timers.setTimeout(() => {
      pending = undefined
      emit("running")
    }, wait)
  }

  emit("running")

  return {
    status: (text) => {
      const trimmed = truncateText(text, CODEVISOR_EXECUTION_MAX_STATUS)
      status = trimmed.length === 0 ? undefined : trimmed
      scheduleRunning()
    },
    call: ({ files, error, ...call }) => {
      // The workflow's first files are what it was for; later ones are cut.
      const shown = files?.slice(0, Math.max(0, CODEVISOR_EXECUTION_MAX_FILES - filesShown)) ?? []
      filesShown += shown.length
      calls.push({
        ...call,
        ...(shown.length === 0 ? {} : { files: shown }),
        ...(error === undefined
          ? {}
          : { error: errorSummary(error, CODEVISOR_EXECUTION_MAX_ERROR) })
      })
      if (calls.length > CODEVISOR_EXECUTION_MAX_CALLS) calls.shift()
      scheduleRunning()
    },
    touch: (next) => {
      if (finished) return
      // A site a browser call reached names the workflow better than the
      // bare browser it started with.
      const named =
        icon === undefined || (isBareBrowser(icon) && next.kind === "site") ? next : icon
      if (sameIcon(named, icon) && sameIcon(next, activeIcon)) return
      icon = named
      activeIcon = next
      scheduleRunning()
    },
    finish: async (error) => {
      if (!finished) {
        finished = true
        if (pending !== undefined) timers.clearTimeout(pending)
        pending = undefined
        emit(
          error === undefined ? "completed" : "failed",
          error === undefined ? undefined : errorSummary(error, CODEVISOR_EXECUTION_MAX_ERROR)
        )
      }
      await delivery
    }
  }
}

/// Reports a `skills` call to the session sink, so a row that ran it from
/// inside its own code can say which skill it read. Never fails the call.
export const reportSkillRead = async (
  sink: RuntimeEventSink | undefined,
  sessionId: string,
  skill: CodevisorSkillRead
): Promise<void> => {
  if (sink === undefined) return
  try {
    await sink({
      kind: "session.output",
      subjectId: sessionId,
      payload: { kind: "codevisor_skill", skill }
    })
  } catch {
    // The read happened; only its label is lost.
  }
}

const BUILTIN_ICON_IDS = new Set(["browser", "computer", "codevisor", "plugin"] as const)

/// The artwork a sandbox call shows on its workflow before it runs: one of
/// Codevisor's own capabilities, or the MCP server it reaches. Catalog
/// lookups (`search`, `describe.tool`) touch nothing worth showing.
export const executionCallIcon = async (
  path: string,
  serverHost: (serverId: string) => Promise<string | undefined>
): Promise<CodevisorExecutionIcon | undefined> => {
  const separator = path.indexOf(".")
  if (separator <= 0) return undefined
  const serverId = path.slice(0, separator)
  if (serverId === "describe") return undefined
  for (const id of BUILTIN_ICON_IDS) {
    if (id === serverId) return { kind: "builtin", id }
  }
  const host = await serverHost(serverId).catch(() => undefined)
  return { kind: "mcp", serverId, ...(host === undefined ? {} : { host }) }
}

/// The site a page URL belongs to, as a workflow icon.
export const siteIcon = (url: string): CodevisorExecutionIcon | undefined => {
  try {
    const parsed = new URL(url)
    if (parsed.protocol !== "https:" && parsed.protocol !== "http:") return undefined
    return { kind: "site", origin: parsed.origin }
  } catch {
    return undefined
  }
}

const SCRIPT_CELLS: Readonly<Record<string, string>> = {
  "browser.js": "Used the browser",
  "computer.js": "Used the desktop"
}

/// A tool name (or a script cell's path) as a step label:
/// `search_models` → "Search models", `browser.js` → "Used the browser".
export const humanizeToolName = (name: string): string => {
  const cell = SCRIPT_CELLS[name]
  if (cell !== undefined) return cell
  if (name === "js" || name.endsWith(".js")) return "Ran a script"
  const words = name
    .replace(/([a-z0-9])([A-Z])/g, "$1 $2")
    .replace(/[._-]+/g, " ")
    .trim()
    .toLowerCase()
  return words.length === 0 ? name : words.charAt(0).toUpperCase() + words.slice(1)
}

/// The files a call's result references: stored artifacts (screenshots,
/// exports) and published recordings, each carrying a server `fileId`.
export const executionFiles = (value: unknown): Array<CodevisorExecutionFile> => {
  const files = new Map<string, CodevisorExecutionFile>()
  const visit = (node: unknown, depth: number): void => {
    if (depth > 5 || files.size >= CODEVISOR_EXECUTION_MAX_FILES) return
    if (Array.isArray(node)) {
      for (const item of node.slice(0, 50)) visit(item, depth + 1)
      return
    }
    if (typeof node !== "object" || node === null) return
    const record = node as Record<string, unknown>
    if (typeof record.fileId === "string" && !files.has(record.fileId)) {
      const mimeType = record.mediaType ?? record.mimeType
      files.set(record.fileId, {
        fileId: record.fileId,
        ...(typeof record.name === "string" ? { name: record.name } : {}),
        ...(typeof mimeType === "string" ? { mimeType } : {})
      })
      return
    }
    for (const child of Object.values(record).slice(0, 50)) visit(child, depth + 1)
  }
  visit(value, 0)
  return [...files.values()]
}
