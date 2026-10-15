import { createHash } from "node:crypto"

import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { canonicalExecutionArgs } from "@codevisor/api"

type ForwardedRecord = Readonly<Record<string, unknown>>

const executeToolTitles = new Set([
  "mcp__codevisor__execute",
  "codevisor.execute",
  "codevisor_execute",
  "codevisor__execute"
])
const pendingTtlMs = 30_000
const maxPendingPerSession = 16
const maxTrackedCallsPerSession = 64
const settledStatuses = new Set(["in_progress", "completed", "failed"])

interface TrackedCall {
  title?: string
  host?: boolean
  hostRunning?: boolean
  parentToolCallId?: string
  meta?: Record<string, unknown>
  execution?: ForwardedRecord
  skill?: ForwardedRecord
  argsHash?: string
}

interface PendingExecution {
  readonly execution: ForwardedRecord
  readonly receivedAt: number
}

interface SessionState {
  readonly calls: Map<string, TrackedCall>
  readonly toolCallsByHash: Map<string, string>
  readonly pending: Map<string, PendingExecution>
}

export class ExecutionAnnotator {
  private readonly sessions = new Map<string, SessionState>()

  constructor(private readonly now: () => number = Date.now) {}

  annotate(sessionId: string, event: RuntimeEvent): ReadonlyArray<RuntimeEvent> {
    const payload = isRecord(event.payload) ? event.payload : {}
    if (payload.kind === "codevisor_execution") {
      return this.receiveExecution(sessionId, event, payload)
    }
    if (payload.kind === "codevisor_skill") return this.receiveSkillRead(sessionId, event, payload)
    if (
      (payload.sessionUpdate === "tool_call" || payload.sessionUpdate === "tool_call_update") &&
      typeof payload.toolCallId === "string"
    ) {
      return this.receiveToolCall(sessionId, event, payload, payload.toolCallId)
    }
    return [event]
  }

  endSession(sessionId: string): void {
    this.sessions.delete(sessionId)
  }

  private receiveExecution(
    sessionId: string,
    event: RuntimeEvent,
    payload: Record<string, unknown>
  ): ReadonlyArray<RuntimeEvent> {
    const { argsHash, execution } = payload
    if (typeof argsHash !== "string" || !isRecord(execution)) return []
    const state = this.session(sessionId)
    const toolCallId = state.toolCallsByHash.get(argsHash) ?? this.adoptByHost(state, argsHash)
    if (toolCallId === undefined) {
      this.prunePending(state)
      state.pending.delete(argsHash)
      state.pending.set(argsHash, {
        execution,
        receivedAt: this.now()
      })
      if (state.pending.size > maxPendingPerSession) {
        state.pending.delete(state.pending.keys().next().value!)
      }
      return []
    }
    return [annotation(event, toolCallId, state.calls.get(toolCallId)!, execution)]
  }

  private receiveToolCall(
    sessionId: string,
    event: RuntimeEvent,
    payload: Record<string, unknown>,
    toolCallId: string
  ): ReadonlyArray<RuntimeEvent> {
    let state = this.sessions.get(sessionId)
    let tracked = state?.calls.get(toolCallId)
    if (tracked === undefined) {
      const title = typeof payload.title === "string" ? payload.title : undefined
      const host = title !== undefined && isHostTitle(title)
      if (title === undefined || (!host && !isExecuteTitle(title))) return [event]
      state ??= this.session(sessionId)
      tracked = host ? { host } : {}
      state.calls.set(toolCallId, tracked)
      if (state.calls.size > maxTrackedCallsPerSession) {
        const [evictedId] = state.calls.keys()
        state.calls.delete(evictedId!)
        for (const [hash, id] of state.toolCallsByHash)
          if (id === evictedId) state.toolCallsByHash.delete(hash)
      }
    }
    state = state!
    if (tracked.host === true)
      return this.receiveHostCall(state, event, payload, toolCallId, tracked)
    if (typeof payload.title === "string") tracked.title = payload.title
    if (typeof payload.parentToolCallId === "string") {
      tracked.parentToolCallId = payload.parentToolCallId
    }
    let published = event
    if (isRecord(payload._meta)) {
      const { codevisorExecution: _, ...meta } = payload._meta
      tracked.meta = meta
      if (tracked.execution !== undefined) {
        published = {
          ...event,
          payload: { ...payload, _meta: { ...meta, codevisorExecution: tracked.execution } }
        }
      }
    }
    const argsHash = executionArgsHash(payload)
    if (argsHash === undefined || argsHash === tracked.argsHash) return [published]
    if (tracked.argsHash !== undefined) state.toolCallsByHash.delete(tracked.argsHash)
    tracked.argsHash = argsHash
    state.toolCallsByHash.set(argsHash, toolCallId)
    this.prunePending(state)
    const pending = state.pending.get(argsHash)
    if (pending === undefined) return [published]
    state.pending.delete(argsHash)
    return [published, annotation(event, toolCallId, tracked, pending.execution)]
  }

  private receiveHostCall(
    state: SessionState,
    event: RuntimeEvent,
    payload: Record<string, unknown>,
    toolCallId: string,
    tracked: TrackedCall
  ): ReadonlyArray<RuntimeEvent> {
    let published = event
    if (isRecord(payload._meta)) {
      const { codevisorExecution: _, codevisorSkill: __, ...meta } = payload._meta
      tracked.meta = meta
    }
    if (tracked.execution !== undefined || tracked.skill !== undefined) {
      published = { ...event, payload: { ...payload, _meta: annotatedMeta(tracked) } }
    }
    const status = String(payload.status)
    if (status === "completed" || status === "failed") {
      tracked.hostRunning = false
      return [published]
    }
    const input = payload.rawInput
    if (!isRecord(input) || typeof input.code !== "string" || tracked.hostRunning === true)
      return [published]
    tracked.hostRunning = true
    this.prunePending(state)
    const waiting = [...state.pending]
    if (waiting.length === 0) return [published]
    for (const [hash] of waiting) {
      state.pending.delete(hash)
      state.toolCallsByHash.set(hash, toolCallId)
    }
    return [published, annotation(event, toolCallId, tracked, waiting.at(-1)![1].execution)]
  }

  private receiveSkillRead(
    sessionId: string,
    event: RuntimeEvent,
    payload: Record<string, unknown>
  ): ReadonlyArray<RuntimeEvent> {
    const state = this.sessions.get(sessionId)
    const running = state === undefined ? undefined : runningHost(state)
    if (running === undefined || !isRecord(payload.skill)) return []
    const [toolCallId, tracked] = running
    tracked.skill = payload.skill
    return [annotationEvent(event, toolCallId, tracked)]
  }

  private adoptByHost(state: SessionState, argsHash: string): string | undefined {
    const running = runningHost(state)
    if (running === undefined) return undefined
    state.toolCallsByHash.set(argsHash, running[0])
    return running[0]
  }

  private session(sessionId: string): SessionState {
    let state = this.sessions.get(sessionId)
    if (state === undefined) {
      state = { calls: new Map(), toolCallsByHash: new Map(), pending: new Map() }
      this.sessions.set(sessionId, state)
    }
    return state
  }

  private prunePending(state: SessionState): void {
    const cutoff = this.now() - pendingTtlMs
    for (const [hash, pending] of state.pending) {
      if (pending.receivedAt < cutoff) state.pending.delete(hash)
    }
  }
}

const runningHost = (state: SessionState): [string, TrackedCall] | undefined =>
  [...state.calls].findLast(([, call]) => call.hostRunning === true)

const annotatedMeta = (tracked: TrackedCall): Record<string, unknown> => ({
  ...tracked.meta,
  ...(tracked.execution === undefined ? {} : { codevisorExecution: tracked.execution }),
  ...(tracked.skill === undefined ? {} : { codevisorSkill: tracked.skill })
})

const annotationEvent = (
  source: RuntimeEvent,
  toolCallId: string,
  tracked: TrackedCall
): RuntimeEvent => ({
  kind: "session.output",
  subjectId: source.subjectId,
  payload: {
    sessionUpdate: "tool_call_update",
    toolCallId,
    ...(tracked.parentToolCallId === undefined
      ? {}
      : { parentToolCallId: tracked.parentToolCallId }),
    _meta: annotatedMeta(tracked)
  }
})

const annotation = (
  source: RuntimeEvent,
  toolCallId: string,
  tracked: TrackedCall,
  execution: ForwardedRecord
): RuntimeEvent => {
  tracked.execution = execution
  return annotationEvent(source, toolCallId, tracked)
}

const isExecuteTitle = (title: string): boolean => executeToolTitles.has(title.trim().toLowerCase())

const isHostTitle = (title: string): boolean => title.trim().toLowerCase() === "execute"

const executionArgsHash = (payload: Record<string, unknown>): string | undefined => {
  const input = payload.rawInput
  if (!isRecord(input) || typeof input.code !== "string") return undefined
  if (typeof input.description !== "string" && !settledStatuses.has(String(payload.status))) {
    return undefined
  }
  return createHash("sha256").update(canonicalExecutionArgs(input)).digest("hex")
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value)
