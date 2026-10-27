import { createHash } from "node:crypto"

import type { RuntimeEventSink } from "@codevisor/agent-runtime"
import {
  canonicalExecutionArgs,
  CODEVISOR_EXECUTION_MAX_APPS,
  CODEVISOR_EXECUTION_MAX_CALLS,
  CODEVISOR_EXECUTION_MAX_DESCRIPTION,
  CODEVISOR_EXECUTION_MAX_ERROR,
  CODEVISOR_EXECUTION_MAX_FILES,
  CODEVISOR_EXECUTION_MAX_STATUS,
  type CodevisorExecutionApp,
  type CodevisorExecutionCall,
  type CodevisorExecutionFile,
  type CodevisorExecutionIcon,
  type CodevisorExecutionState,
  type CodevisorSkillRead
} from "@codevisor/api"
import type { ComputerUseApp } from "@codevisor/automation"

import { isRecord } from "./mcp-guards.js"

export const EXECUTION_EMIT_INTERVAL_MS = 250

export interface ExecutionTimers {
  readonly now: () => number
  readonly setTimeout: (callback: () => void, ms: number) => () => void
}

export const systemExecutionTimers: ExecutionTimers = {
  now: () => performance.now(),
  setTimeout: (callback, ms) => {
    const handle = setTimeout(callback, ms)
    return () => clearTimeout(handle)
  }
}

export const EXECUTE_DEFAULT_TIMEOUT_MS = 120_000
export const EXECUTE_MAX_TIMEOUT_MS = 600_000

export const truncateText = (text: string, max: number): string => {
  const collapsed = text.replace(/\s+/g, " ").trim()
  return collapsed.length <= max ? collapsed : `${collapsed.slice(0, max - 1).trimEnd()}…`
}

export const errorSummary = (error: string, max: number): string => {
  const firstLine = error.split("\n").find((line) => line.trim().length > 0) ?? error
  const message = firstLine
    .replace(/^\s*(?:[A-Za-z]*Error:\s*)+/, "")
    .replace(/\s+at\s+(?:<anonymous>|[\w$.]+\s*\(|file:|node:).*$/, "")
  return truncateText(message.length > 0 ? message : firstLine, max)
}

export const executionArgsHash = (args: {
  readonly code: string
  readonly description: string
  readonly timeout_ms?: number
}): string => createHash("sha256").update(canonicalExecutionArgs(args)).digest("hex")

export interface ExecutionRecorder {
  readonly status: (text: string) => void
  readonly call: (call: CodevisorExecutionCall) => void
  readonly touch: (icon: CodevisorExecutionIcon) => void
  readonly app: (app: CodevisorExecutionApp) => void
  readonly finish: (error?: string) => Promise<void>
}

const sameIcon = (
  lhs: CodevisorExecutionIcon | undefined,
  rhs: CodevisorExecutionIcon | undefined
): boolean => JSON.stringify(lhs) === JSON.stringify(rhs)

const isBareSurface = (icon: CodevisorExecutionIcon, next: CodevisorExecutionIcon): boolean =>
  icon.kind === "builtin" &&
  ((icon.id === "browser" && next.kind === "site") ||
    (icon.id === "computer" && next.kind === "app"))

export const makeExecutionRecorder = (options: {
  readonly sink: RuntimeEventSink | undefined
  readonly sessionId: string
  readonly argsHash: string
  readonly description?: string
  readonly timers?: ExecutionTimers
}): ExecutionRecorder => {
  const { sink, sessionId, argsHash } = options
  const timers = options.timers ?? systemExecutionTimers
  const firstLine = options.description?.split("\n").find((line) => line.trim().length > 0)
  const description =
    firstLine === undefined
      ? undefined
      : truncateText(firstLine, CODEVISOR_EXECUTION_MAX_DESCRIPTION)
  const calls: Array<CodevisorExecutionCall> = []
  const apps: Array<CodevisorExecutionApp> = []
  let filesShown = 0
  let status: string | undefined
  let icon: CodevisorExecutionIcon | undefined
  let activeIcon: CodevisorExecutionIcon | undefined
  let lastEmitAt = Number.NEGATIVE_INFINITY
  let cancelPending: (() => void) | undefined
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
      ...(apps.length === 0 ? {} : { apps: [...apps] }),
      ...(error === undefined ? {} : { error }),
      ...(icon === undefined ? {} : { icon }),
      ...(activeIcon === undefined ? {} : { activeIcon })
    }
    const event = {
      kind: "session.output" as const,
      subjectId: sessionId,
      payload: { kind: "codevisor_execution", argsHash, execution }
    }
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
    if (finished || cancelPending !== undefined) return
    const wait = lastEmitAt + EXECUTION_EMIT_INTERVAL_MS - timers.now()
    if (wait <= 0) {
      emit("running")
      return
    }
    cancelPending = timers.setTimeout(() => {
      cancelPending = undefined
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
    app: (next) => {
      apps.push(next)
      if (apps.length > CODEVISOR_EXECUTION_MAX_APPS) apps.shift()
      scheduleRunning()
    },
    touch: (next) => {
      if (finished) return
      const named = icon === undefined || isBareSurface(icon, next) ? next : icon
      if (sameIcon(named, icon) && sameIcon(next, activeIcon)) return
      icon = named
      activeIcon = next
      scheduleRunning()
    },
    finish: async (error) => {
      if (!finished) {
        finished = true
        cancelPending?.()
        cancelPending = undefined
        emit(
          error === undefined ? "completed" : "failed",
          error === undefined ? undefined : errorSummary(error, CODEVISOR_EXECUTION_MAX_ERROR)
        )
      }
      await delivery
    }
  }
}

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
  } catch {}
}

const BUILTIN_ICON_IDS = new Set(["browser", "computer", "codevisor", "plugin"] as const)

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

export const appIcon = (app: ComputerUseApp): CodevisorExecutionIcon => ({
  kind: "app",
  bundleId: app.bundleId,
  ...(app.name === undefined ? {} : { name: app.name }),
  ...(app.path === undefined ? {} : { path: app.path })
})

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

export const executionFiles = (value: unknown): Array<CodevisorExecutionFile> => {
  const files = new Map<string, CodevisorExecutionFile>()
  const visit = (node: unknown, depth: number): void => {
    if (depth > 5 || files.size >= CODEVISOR_EXECUTION_MAX_FILES) return
    if (Array.isArray(node)) {
      for (const item of node.slice(0, 50)) visit(item, depth + 1)
      return
    }
    if (!isRecord(node)) return
    if (typeof node.fileId === "string" && !files.has(node.fileId)) {
      const mimeType = node.mediaType ?? node.mimeType
      files.set(node.fileId, {
        fileId: node.fileId,
        ...(typeof node.name === "string" ? { name: node.name } : {}),
        ...(typeof mimeType === "string" ? { mimeType } : {})
      })
      return
    }
    for (const child of Object.values(node).slice(0, 50)) visit(child, depth + 1)
  }
  visit(value, 0)
  return [...files.values()]
}
