import { createHash } from "node:crypto"

import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { canonicalExecutionArgs, type CodevisorExecutionState } from "@codevisor/api"

/// How each harness names the gateway's `execute` tool on its tool rows.
const executeToolTitles = new Set([
  "mcp__codevisor__execute",
  "codevisor.execute",
  "codevisor_execute",
  "codevisor__execute"
])
/// A gateway event can outrun the harness event that carries the arguments.
/// Only the latest state per execution is kept, and only briefly.
const pendingTtlMs = 30_000
const maxPendingPerSession = 16
const maxTrackedCallsPerSession = 64
const settledStatuses = new Set(["in_progress", "completed", "failed"])

interface TrackedCall {
  title?: string
  /// A harness's own code tool (OpenCode's Code Mode `execute`), which runs
  /// the gateway from inside its script: its arguments are the harness's
  /// code, never the gateway's, so gateway runs attach to it while it runs.
  host?: boolean
  /// The host is running its code: gateway runs now come from it.
  hostRunning?: boolean
  parentToolCallId?: string
  /// The harness's own `_meta`, kept so annotations merge into it instead of
  /// replacing it (the transcript projection replaces top-level fields).
  meta?: Record<string, unknown>
  execution?: CodevisorExecutionState
  argsHash?: string
}

interface PendingExecution {
  readonly execution: CodevisorExecutionState
  readonly receivedAt: number
}

interface SessionState {
  readonly calls: Map<string, TrackedCall>
  readonly toolCallsByHash: Map<string, string>
  readonly pending: Map<string, PendingExecution>
}

/// Attaches the gateway's live execution state (status, nested calls, error)
/// to the harness tool row that ran it. The gateway never learns the
/// harness's tool call id, so both sides hash the same `execute` arguments.
export class ExecutionAnnotator {
  private readonly sessions = new Map<string, SessionState>()

  constructor(private readonly now: () => number = Date.now) {}

  /// The events to materialize, in order, in place of `event`. Gateway
  /// events become `tool_call_update`s for the correlated row, or nothing.
  annotate(sessionId: string, event: RuntimeEvent): ReadonlyArray<RuntimeEvent> {
    const payload = isRecord(event.payload) ? event.payload : {}
    if (payload.kind === "codevisor_execution") {
      return this.receiveExecution(sessionId, event, payload)
    }
    if (
      (payload.sessionUpdate === "tool_call" || payload.sessionUpdate === "tool_call_update") &&
      typeof payload.toolCallId === "string"
    ) {
      return this.receiveToolCall(sessionId, event, payload, payload.toolCallId)
    }
    return [event]
  }

  /// Forgets a session's correlations once its turn is over.
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
        execution: execution as unknown as CodevisorExecutionState,
        receivedAt: this.now()
      })
      if (state.pending.size > maxPendingPerSession) {
        state.pending.delete(state.pending.keys().next().value!)
      }
      return []
    }
    return [
      annotation(
        event,
        toolCallId,
        state.calls.get(toolCallId)!,
        execution as unknown as CodevisorExecutionState
      )
    ]
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

  /// A host's own update. Once it runs code, gateway runs that arrived
  /// before it did are its own.
  private receiveHostCall(
    state: SessionState,
    event: RuntimeEvent,
    payload: Record<string, unknown>,
    toolCallId: string,
    tracked: TrackedCall
  ): ReadonlyArray<RuntimeEvent> {
    let published = event
    if (isRecord(payload._meta)) {
      const { codevisorExecution: _, ...meta } = payload._meta
      tracked.meta = meta
    }
    if (tracked.execution !== undefined) {
      published = {
        ...event,
        payload: { ...payload, _meta: { ...tracked.meta, codevisorExecution: tracked.execution } }
      }
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

  /// The running host a gateway run with no row of its own came from: the
  /// most recent one, since a harness runs one tool call at a time.
  private adoptByHost(state: SessionState, argsHash: string): string | undefined {
    const running = [...state.calls].findLast(([, call]) => call.hostRunning === true)
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

const annotation = (
  source: RuntimeEvent,
  toolCallId: string,
  tracked: TrackedCall,
  execution: CodevisorExecutionState
): RuntimeEvent => {
  tracked.execution = execution
  return {
    kind: "session.output",
    subjectId: source.subjectId,
    payload: {
      sessionUpdate: "tool_call_update",
      toolCallId,
      // Keeps subagent rows attached to their parent in the projection.
      ...(tracked.parentToolCallId === undefined
        ? {}
        : { parentToolCallId: tracked.parentToolCallId }),
      _meta: { ...tracked.meta, codevisorExecution: execution }
    }
  }
}

const isExecuteTitle = (title: string): boolean => executeToolTitles.has(title.trim().toLowerCase())

/// OpenCode 2 names its Code Mode tool plain `execute`; the gateway's own
/// tool always carries its server's name.
const isHostTitle = (title: string): boolean => title.trim().toLowerCase() === "execute"

/// Claude streams tool input, so a partial input is not hashed until the
/// call is running or both fields the gateway requires are present.
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
