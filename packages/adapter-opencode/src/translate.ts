import { record, type JsonRecord } from "./internal.js"
import {
  completedToolUpdate,
  failedToolUpdate,
  pendingToolCall,
  runningToolUpdate,
  type ToolCallState
} from "./tool-updates.js"

export interface OpenCodeEvent {
  readonly type: string
  readonly data: JsonRecord
}

export interface ChildSession {
  readonly id: string
  readonly parentID: string
  readonly depth: number
  readonly title?: string
}

export interface TrackedTool {
  readonly sessionID: string
  readonly id: string
  readonly name: string
  readonly input: JsonRecord
  readonly metadata: JsonRecord
}

export interface Tokens {
  readonly input: number
  readonly output: number
  readonly reasoning: number
  readonly cache: { readonly read: number; readonly write: number }
}

export interface TurnErrorInfo {
  readonly type: string
  readonly message: string
}

export interface TurnState {
  readonly inputID: string
  readonly started: boolean
  readonly pending: ReadonlySet<string>
  readonly finish?: string
  readonly usage?: { readonly turn: Tokens; readonly last: Tokens }
  readonly stepError?: TurnErrorInfo | undefined
  readonly executionError?: TurnErrorInfo
}

export interface FoldState {
  readonly sessionID: string
  readonly cwd: string
  readonly tools: ReadonlyMap<string, TrackedTool>
  readonly children: ReadonlyMap<string, ChildSession>
  readonly turn?: TurnState | undefined
}

export type Terminal = "succeeded" | "failed" | "interrupted"

export type FoldOutput =
  | { readonly _tag: "update"; readonly update: JsonRecord; readonly metadata?: JsonRecord }
  | { readonly _tag: "child"; readonly params: JsonRecord; readonly metadata?: JsonRecord }
  | {
      readonly _tag: "permission"
      readonly request: JsonRecord
      readonly tool?: TrackedTool
      readonly child?: ChildSession
    }
  | { readonly _tag: "permissionSettled"; readonly id: string }
  | { readonly _tag: "form"; readonly form: JsonRecord }
  | { readonly _tag: "terminal"; readonly terminal: Terminal }

export interface Folded {
  readonly state: FoldState
  readonly outputs: ReadonlyArray<FoldOutput>
}

export const RETRY_META = "opencode/retry"
export const CHILD_SESSION_META = "opencode/child-session"

export const initialFoldState = (sessionID: string, cwd: string): FoldState => ({
  sessionID,
  cwd,
  tools: new Map(),
  children: new Map()
})

export const decodeEvent = (value: unknown): OpenCodeEvent | undefined => {
  const event = record(value)
  const data = record(event?.data)
  return typeof event?.type === "string" && data !== undefined
    ? { type: event.type, data }
    : undefined
}

const text = (value: unknown): string | undefined =>
  typeof value === "string" && value !== "" ? value : undefined

const number = (value: unknown): number => (typeof value === "number" ? value : 0)

export const decodeTokens = (value: unknown): Tokens | undefined => {
  const tokens = record(value)
  if (tokens === undefined) return undefined
  const cache = record(tokens.cache)
  return {
    input: number(tokens.input),
    output: number(tokens.output),
    reasoning: number(tokens.reasoning),
    cache: { read: number(cache?.read), write: number(cache?.write) }
  }
}

export const totalTokens = (tokens: Tokens): number =>
  tokens.input + tokens.output + tokens.reasoning + tokens.cache.read + tokens.cache.write

const errorInfo = (value: unknown): TurnErrorInfo | undefined => {
  const error = record(value)
  return typeof error?.type === "string"
    ? { type: error.type, message: typeof error.message === "string" ? error.message : "" }
    : undefined
}

const without = <K, V>(map: ReadonlyMap<K, V>, key: K): Map<K, V> => {
  const next = new Map(map)
  next.delete(key)
  return next
}

const toolKey = (sessionID: string, id: string) => `${sessionID}:${id}`

export const childToolCallId = (child: ChildSession | undefined, id: string): string =>
  child === undefined ? id : `${child.id}:${id}`

export const prefixChildTitle = (child: ChildSession | undefined, title: string): string =>
  child?.title === undefined ? title : `${child.title}: ${title}`

const childMeta = (child: ChildSession): JsonRecord => ({
  [CHILD_SESSION_META]: {
    id: child.id,
    parentID: child.parentID,
    depth: child.depth,
    ...(child.title === undefined ? {} : { title: child.title })
  }
})

const childParams = (rootID: string, child: ChildSession, event: JsonRecord): JsonRecord => ({
  rootSessionId: rootID,
  childSessionId: child.id,
  parentSessionId: child.parentID,
  depth: child.depth,
  ...(child.title === undefined ? {} : { title: child.title }),
  ...event
})

const project = (update: JsonRecord, child: ChildSession): JsonRecord => {
  const projected: JsonRecord = {
    ...update,
    _meta: { ...record(update._meta), ...childMeta(child) }
  }
  if (typeof projected.toolCallId === "string")
    projected.toolCallId = childToolCallId(child, projected.toolCallId)
  if (typeof projected.title === "string")
    projected.title = prefixChildTitle(child, projected.title)
  return projected
}

const route = (
  state: FoldState,
  child: ChildSession | undefined,
  update: JsonRecord,
  metadata?: JsonRecord
): FoldOutput => {
  const extra = metadata === undefined ? {} : { metadata }
  if (child === undefined) return { _tag: "update", update, ...extra }
  return {
    _tag: "child",
    params: childParams(state.sessionID, child, { type: "update", update: project(update, child) }),
    ...extra
  }
}

const childStatus = (state: FoldState, child: ChildSession, status: string): FoldOutput => ({
  _tag: "child",
  params: childParams(state.sessionID, child, { type: "status", status })
})

const sessionOf = (event: OpenCodeEvent): string | undefined =>
  text(event.data.sessionID) ?? text(record(event.data.form)?.sessionID)

export const withTurn = (state: FoldState, turn: Partial<TurnState>): FoldState =>
  state.turn === undefined ? state : { ...state, turn: { ...state.turn, ...turn } }

const toolState = (state: FoldState, tool: TrackedTool): ToolCallState => ({
  toolCallId: tool.id,
  toolName: tool.name,
  input: tool.input,
  cwd: state.cwd
})

const newTool = (sessionID: string, id: string, name = "tool"): TrackedTool => ({
  sessionID,
  id,
  name,
  input: {},
  metadata: {}
})

const addTokens = (left: Tokens, right: Tokens): Tokens => ({
  input: left.input + right.input,
  output: left.output + right.output,
  reasoning: left.reasoning + right.reasoning,
  cache: { read: left.cache.read + right.cache.read, write: left.cache.write + right.cache.write }
})

const recordStep = (state: FoldState, value: unknown): FoldState => {
  const tokens = decodeTokens(value)
  const turn = state.turn
  if (tokens === undefined || turn === undefined) return state
  const total = turn.usage === undefined ? tokens : addTokens(turn.usage.turn, tokens)
  return withTurn(state, { usage: { turn: total, last: tokens } })
}

const childCreated = (state: FoldState, event: OpenCodeEvent): Folded => {
  const parentID = text(event.data.parentID)
  const sessionID = text(event.data.sessionID)
  const parent = parentID === undefined ? undefined : state.children.get(parentID)
  if (sessionID === undefined || (parentID !== state.sessionID && parent === undefined))
    return { state, outputs: [] }
  const title = text(event.data.title)
  const child: ChildSession = {
    id: sessionID,
    parentID: parentID!,
    depth: parent === undefined ? 1 : parent.depth + 1,
    ...(title === undefined ? {} : { title })
  }
  const next = { ...state, children: new Map(state.children).set(child.id, child) }
  return { state: next, outputs: [childStatus(next, child, "created")] }
}

const contentEvent = (
  state: FoldState,
  event: OpenCodeEvent,
  child: ChildSession | undefined
): Folded => {
  const sessionID = child?.id ?? state.sessionID
  const data = event.data
  const send = (update: JsonRecord, metadata?: JsonRecord): Folded => ({
    state,
    outputs: [route(state, child, update, metadata)]
  })
  const key = typeof data.id === "string" ? toolKey(sessionID, data.id) : undefined
  const current = key === undefined ? undefined : state.tools.get(key)
  switch (event.type) {
    case "session.retry.scheduled":
      return send({
        sessionUpdate: "session_info_update",
        _meta: {
          [RETRY_META]: {
            attempt: data.attempt,
            nextRetryAt: new Date(number(data.at)).toISOString(),
            error: data.error
          }
        }
      })
    case "session.text.delta":
      return send({
        sessionUpdate: "agent_message_chunk",
        messageId: data.assistantMessageID,
        content: { type: "text", text: typeof data.delta === "string" ? data.delta : "" }
      })
    case "session.reasoning.delta":
      return send({
        sessionUpdate: "agent_thought_chunk",
        messageId: `${String(data.assistantMessageID)}:reasoning:${number(data.ordinal)}`,
        content: { type: "text", text: typeof data.delta === "string" ? data.delta : "" }
      })
    default:
      break
  }
  if (key === undefined || typeof data.id !== "string") return { state, outputs: [] }
  switch (event.type) {
    case "session.tool.input.started": {
      const tool = newTool(sessionID, data.id, text(data.name))
      return {
        state: { ...state, tools: new Map(state.tools).set(key, tool) },
        outputs: [
          route(state, child, {
            sessionUpdate: "tool_call",
            ...pendingToolCall(toolState(state, tool))
          })
        ]
      }
    }
    case "session.tool.called": {
      const tool = { ...(current ?? newTool(sessionID, data.id)), input: record(data.input) ?? {} }
      return {
        state: { ...state, tools: new Map(state.tools).set(key, tool) },
        outputs: [
          route(state, child, {
            sessionUpdate: "tool_call_update",
            ...runningToolUpdate(toolState(state, tool))
          })
        ]
      }
    }
    case "session.tool.progress": {
      if (current === undefined) return { state, outputs: [] }
      const tool = { ...current, metadata: record(data.metadata) ?? {} }
      return {
        state: { ...state, tools: new Map(state.tools).set(key, tool) },
        outputs: [
          route(state, child, {
            sessionUpdate: "tool_call_update",
            ...runningToolUpdate(toolState(state, tool))
          })
        ]
      }
    }
    case "session.tool.success": {
      const tool = current ?? newTool(sessionID, data.id)
      const metadata = record(data.metadata)
      const content = Array.isArray(data.content) ? data.content : []
      return {
        state: { ...state, tools: without(state.tools, key) },
        outputs: [
          route(
            state,
            child,
            {
              sessionUpdate: "tool_call_update",
              ...completedToolUpdate(toolState(state, tool), content, metadata)
            },
            metadata
          )
        ]
      }
    }
    case "session.tool.failed": {
      const tool = current ?? newTool(sessionID, data.id)
      const content = Array.isArray(data.content) ? data.content : []
      const metadata = record(data.metadata) ?? tool.metadata
      const message = errorInfo(data.error)?.message ?? "Tool failed"
      return {
        state: { ...state, tools: without(state.tools, key) },
        outputs: [
          route(state, child, {
            sessionUpdate: "tool_call_update",
            ...failedToolUpdate(toolState(state, tool), content, metadata, message)
          })
        ]
      }
    }
    default:
      return { state, outputs: [] }
  }
}

const rootEvent = (state: FoldState, event: OpenCodeEvent): Folded => {
  switch (event.type) {
    case "session.step.started":
      return { state: withTurn(state, { stepError: undefined }), outputs: [] }
    case "session.step.ended": {
      const finish = text(event.data.finish)
      const recorded = recordStep(state, event.data.tokens)
      return {
        state: finish === undefined ? recorded : withTurn(recorded, { finish }),
        outputs: []
      }
    }
    case "session.step.failed": {
      const stepError = errorInfo(event.data.error)
      const recorded = recordStep(state, event.data.tokens)
      return {
        state: stepError === undefined ? recorded : withTurn(recorded, { stepError }),
        outputs: []
      }
    }
    case "session.execution.succeeded":
      return { state, outputs: [{ _tag: "terminal", terminal: "succeeded" }] }
    case "session.execution.interrupted":
      return { state, outputs: [{ _tag: "terminal", terminal: "interrupted" }] }
    case "session.execution.failed": {
      const executionError = errorInfo(event.data.error)
      return {
        state: executionError === undefined ? state : withTurn(state, { executionError }),
        outputs: [{ _tag: "terminal", terminal: "failed" }]
      }
    }
    default:
      return contentEvent(state, event, undefined)
  }
}

const CHILD_TERMINALS: Readonly<Record<string, string>> = {
  "session.execution.started": "running",
  "session.execution.succeeded": "completed",
  "session.execution.interrupted": "interrupted",
  "session.execution.failed": "failed"
}

const childEvent = (state: FoldState, event: OpenCodeEvent, child: ChildSession): Folded => {
  const status = CHILD_TERMINALS[event.type]
  if (status !== undefined) return { state, outputs: [childStatus(state, child, status)] }
  return contentEvent(state, event, child)
}

const delivered = (state: FoldState, inboxID: unknown): Folded => {
  const turn = state.turn
  if (turn === undefined || typeof inboxID !== "string" || !turn.pending.has(inboxID))
    return { state, outputs: [] }
  const pending = new Set(turn.pending)
  pending.delete(inboxID)
  return {
    state: withTurn(state, { pending, ...(inboxID === turn.inputID ? { started: true } : {}) }),
    outputs: []
  }
}

export const foldEvent = (state: FoldState, event: OpenCodeEvent): Folded => {
  if (event.type === "session.created") return childCreated(state, event)
  const sessionID = sessionOf(event)
  const child = sessionID === undefined ? undefined : state.children.get(sessionID)
  const ours = sessionID === state.sessionID || child !== undefined
  if (event.type === "permission.asked" && ours) {
    const source = record(event.data.source)
    const tool =
      typeof source?.id === "string"
        ? state.tools.get(toolKey(String(sessionID), source.id))
        : undefined
    return {
      state,
      outputs: [
        {
          _tag: "permission",
          request: event.data,
          ...(tool === undefined ? {} : { tool }),
          ...(child === undefined ? {} : { child })
        }
      ]
    }
  }
  if (event.type === "permission.replied" && typeof event.data.requestID === "string")
    return { state, outputs: [{ _tag: "permissionSettled", id: event.data.requestID }] }
  if (event.type === "form.created" && ours)
    return { state, outputs: [{ _tag: "form", form: record(event.data.form) ?? {} }] }
  if (!ours) return { state, outputs: [] }
  if (child !== undefined) return childEvent(state, event, child)
  if (event.type === "session.inbox.delivered") return delivered(state, event.data.inboxID)
  if (event.type === "session.renamed" && typeof event.data.title === "string")
    return {
      state,
      outputs: [
        {
          _tag: "update",
          update: { sessionUpdate: "session_info_update", title: event.data.title }
        }
      ]
    }
  if (state.turn?.started !== true) return { state, outputs: [] }
  return rootEvent(state, event)
}

export const abandonTools = (state: FoldState): Folded => ({
  state: {
    ...state,
    tools: new Map([...state.tools].filter(([, tool]) => tool.sessionID !== state.sessionID))
  },
  outputs: [...state.tools.values()]
    .filter((tool) => tool.sessionID === state.sessionID)
    .map((tool) =>
      route(state, undefined, {
        sessionUpdate: "tool_call_update",
        ...failedToolUpdate(toolState(state, tool), [], tool.metadata, "Cancelled")
      })
    )
})

export const turnFailure = (turn: TurnState): TurnErrorInfo | undefined => {
  const error = turn.stepError ?? turn.executionError
  return error === undefined || error.type === "aborted" || error.type === "provider.content-filter"
    ? undefined
    : error
}

export const stopReason = (turn: TurnState, terminal: Terminal): string => {
  const error = (turn.stepError ?? turn.executionError)?.type
  if (terminal === "interrupted" || error === "aborted") return "cancelled"
  if (turn.finish === "length") return "max_tokens"
  if (turn.finish === "content-filter" || error === "provider.content-filter") return "refusal"
  return "end_turn"
}
