import type { RuntimeEvent } from "@codevisor/agent-runtime"

export const CURSOR_SUBAGENTS_CAPABILITY = "subagents"
export const CURSOR_SUBAGENT_METHOD = "codevisor/cursor_subagent"
const SUBAGENT_ANNOUNCEMENTS = new Set(["subagent_spawned", "subagent_state_update"])

const CHILD_THREAD_UPDATES = new Set([
  "agent_message_chunk",
  "agent_thought_chunk",
  "tool_call",
  "tool_call_update"
])

type JsonRecord = Record<string, unknown>

const record = (value: unknown): JsonRecord | undefined =>
  typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as JsonRecord)
    : undefined

const string = (value: unknown): string | undefined =>
  typeof value === "string" && value.length > 0 ? value : undefined

interface CursorTask {
  description?: string
  prompt?: string
  subagentType?: string
  streams: boolean
}

interface CursorChild {
  readonly rootSessionId: string
  readonly callId: string
}

export class CursorSubagents {
  private readonly tasks = new Map<string, CursorTask>()
  private readonly children = new Map<string, CursorChild>()

  isChildSession(sessionId: string): boolean {
    return this.children.has(sessionId)
  }

  mapToolUpdate(sessionId: string, update: JsonRecord): JsonRecord {
    if (update.sessionUpdate !== "tool_call" && update.sessionUpdate !== "tool_call_update") {
      return update
    }
    const id = string(update.toolCallId)
    if (id === undefined) return update
    const key = taskKey(sessionId, id)
    const input = record(update.rawInput)
    let task = this.tasks.get(key)
    if (task === undefined) {
      if (input?._toolName !== "task") return update
      task = { streams: false }
      this.tasks.set(key, task)
    }
    if (input !== undefined) learnTask(task, input)
    const mapped: JsonRecord = { ...update, kind: "agent", rawInput: taskInput(task) }
    if (task.description !== undefined) mapped.title = task.description
    if (
      update.status === "completed" &&
      record(update.rawOutput)?.isBackground === true &&
      task.streams
    ) {
      delete mapped.status
    }
    return mapped
  }

  taskEvent(params: unknown, sessionId: string): RuntimeEvent | undefined {
    const request = record(params)
    const id = string(request?.toolCallId)
    if (request === undefined || id === undefined) return undefined
    const task = this.tasks.get(taskKey(sessionId, id)) ?? { streams: false }
    learnTask(task, request)
    const agentId = string(request.agentId)
    return {
      kind: "session.output",
      subjectId: sessionId,
      payload: {
        ...(agentId === undefined ? {} : { _meta: subagentMeta(agentId) }),
        kind: "agent",
        rawInput: taskInput(task),
        rawOutput: {
          ...(agentId === undefined ? {} : { agentId }),
          ...(typeof request.durationMs === "number" ? { durationMs: request.durationMs } : {}),
          ...(typeof request.model === "string" ? { model: request.model } : {})
        },
        sessionUpdate: "tool_call_update",
        ...(task.description === undefined ? {} : { title: task.description }),
        toolCallId: id
      }
    }
  }

  announcement(params: unknown): ReadonlyArray<RuntimeEvent> {
    const notification = record(params)
    const sessionId = string(notification?.sessionId)
    const update = record(notification?.update)
    const childId = string(update?.subagentSessionId)
    if (sessionId === undefined || update === undefined || childId === undefined) return []
    const cursor = record(record(update._meta)?.cursor)
    if (update.sessionUpdate === "subagent_spawned") {
      const toolCallId = string(cursor?.toolCallId)
      if (toolCallId === undefined) return []
      const parent = this.children.get(sessionId)
      const child: CursorChild = {
        callId: parent === undefined ? toolCallId : `${sessionId}:${toolCallId}`,
        rootSessionId: parent?.rootSessionId ?? sessionId
      }
      this.children.set(childId, child)
      const task = this.tasks.get(taskKey(sessionId, toolCallId))
      if (task !== undefined) task.streams = true
      const agentId = string(cursor?.agentId) ?? childId
      return [
        {
          kind: "session.output",
          subjectId: child.rootSessionId,
          payload: {
            _meta: subagentMeta(agentId),
            sessionUpdate: "tool_call_update",
            toolCallId: child.callId
          }
        }
      ]
    }
    const child = this.children.get(childId)
    const status =
      update.state === "completed"
        ? "completed"
        : update.state === "cancelled"
          ? "cancelled"
          : update.state === "failed" || update.state === "disconnected"
            ? "failed"
            : undefined
    if (update.sessionUpdate !== "subagent_state_update" || child === undefined) return []
    if (status === undefined) return []
    return [
      {
        kind: "session.output",
        subjectId: child.rootSessionId,
        payload: { sessionUpdate: "tool_call_update", status, toolCallId: child.callId }
      }
    ]
  }

  isThreadUpdate(update: JsonRecord): boolean {
    return CHILD_THREAD_UPDATES.has(String(update.sessionUpdate))
  }

  childEvents(
    childSessionId: string,
    events: ReadonlyArray<RuntimeEvent>
  ): ReadonlyArray<RuntimeEvent> {
    const child = this.children.get(childSessionId)
    if (child === undefined) return []
    return events.map((event) => {
      const payload = { ...(event.payload as JsonRecord) }
      const toolCallId = string(payload.toolCallId)
      if (toolCallId !== undefined) payload.toolCallId = `${childSessionId}:${toolCallId}`
      return {
        ...event,
        payload: { ...payload, parentToolCallId: child.callId },
        subjectId: child.rootSessionId
      }
    })
  }
}

export const rerouteCursorSubagentAnnouncement = (message: JsonRecord): JsonRecord => {
  if (message.method !== "session/update" || message.id !== undefined) return message
  const update = record(record(message.params)?.update)
  if (!SUBAGENT_ANNOUNCEMENTS.has(String(update?.sessionUpdate))) return message
  return { ...message, method: CURSOR_SUBAGENT_METHOD }
}

const learnTask = (task: CursorTask, source: JsonRecord): void => {
  const description = string(source.description)
  const prompt = string(source.prompt)
  const type = subagentType(source.subagentType)
  if (description !== undefined) task.description = description
  if (prompt !== undefined) task.prompt = prompt
  if (type !== undefined) task.subagentType = type
}

const taskKey = (sessionId: string, toolCallId: string): string => `${sessionId}\u0000${toolCallId}`

const taskInput = (task: CursorTask): JsonRecord => ({
  ...(task.description === undefined ? {} : { description: task.description }),
  ...(task.prompt === undefined ? {} : { prompt: task.prompt }),
  ...(task.subagentType === undefined ? {} : { subagent_type: task.subagentType })
})

const subagentMeta = (agentId: string): JsonRecord => ({ codevisorSubagent: { taskId: agentId } })

const subagentType = (value: unknown): string | undefined => {
  const named = string(value)
  if (named !== undefined) return named === "unspecified" ? undefined : named
  const variant = record(value)
  const key = variant === undefined ? undefined : Object.keys(variant)[0]
  if (variant === undefined || key === undefined) return undefined
  return key === "custom" ? subagentType(variant.custom) : subagentType(key)
}
