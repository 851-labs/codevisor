import type { RuntimeEvent } from "@codevisor/agent-runtime"

import { objectRecord as record, type JsonRecord } from "./record.js"

const CHILD_THREAD_UPDATES = new Set([
  "agent_message_chunk",
  "agent_thought_chunk",
  "tool_call",
  "tool_call_update"
])

const TASK_TOOL_NAMES = new Set(["task", "Task", "spawn_subagent"])

const string = (value: unknown): string | undefined =>
  typeof value === "string" && value.length > 0 ? value : undefined

const finishedStatus = (update: JsonRecord) => {
  if (update.status === "completed") return "completed"
  if (update.status === "cancelled") return "cancelled"
  if (update.status === "failed") return "failed"
  return undefined
}

interface GrokTask {
  readonly callId: string
  readonly sessionId: string
  description?: string
  prompt?: string
  subagentType?: string
  childId?: string
}

interface GrokChild {
  readonly rootSessionId: string
  readonly callId: string
  readonly taskId: string
  readonly continues: boolean
}

export class GrokSubagents {
  private readonly tasks = new Map<string, GrokTask>()
  private readonly children = new Map<string, GrokChild>()

  isChildSession(sessionId: string): boolean {
    return this.children.has(sessionId)
  }

  sessionOf(params: unknown): string | undefined {
    const outer = record(params)
    const notification = typeof outer?.method === "string" ? record(outer.params) : outer
    return string(notification?.sessionId)
  }

  isThreadUpdate(update: { readonly sessionUpdate: string }): boolean {
    return CHILD_THREAD_UPDATES.has(update.sessionUpdate)
  }

  mapToolEvents(
    sessionId: string,
    events: ReadonlyArray<RuntimeEvent>
  ): ReadonlyArray<RuntimeEvent> {
    return events.map((event) => {
      const payload = record(event.payload)
      return payload === undefined
        ? event
        : { ...event, payload: this.mapToolUpdate(sessionId, payload) }
    })
  }

  private mapToolUpdate(sessionId: string, update: JsonRecord): JsonRecord {
    if (update.sessionUpdate !== "tool_call" && update.sessionUpdate !== "tool_call_update") {
      return update
    }
    const id = string(update.toolCallId)
    if (id === undefined) return update
    const input = record(update.rawInput)
    const tool = record(record(update._meta)?.["x.ai/tool"])
    if (tool?.kind === "active_agent_message") return this.messageToSubagent(update, input)
    const key = taskKey(sessionId, id)
    let task = this.tasks.get(key)
    if (task === undefined) {
      if (!isTaskCall(update, input, tool)) return update
      task = { callId: id, sessionId }
      this.tasks.set(key, task)
    }
    if (input !== undefined) learnTask(task, input)
    const mapped: JsonRecord = { ...update, kind: "agent", rawInput: taskInput(task) }
    if (Object.keys(taskInput(task)).length === 0) delete mapped.rawInput
    if (task.description !== undefined) mapped.title = task.description

    const output = record(update.rawOutput)
    const reported = string(output?.subagent_id) ?? backgroundSubagentId(output)
    if (reported !== undefined) this.link(task, reported)
    if (update.status === "completed" && output?.type === "Text") delete mapped.status
    const child = task.childId === undefined ? undefined : this.children.get(task.childId)
    if (child !== undefined) mapped._meta = { ...record(update._meta), ...subagentMeta(child) }
    return mapped
  }

  notification(params: unknown): ReadonlyArray<RuntimeEvent> {
    const outer = record(params)
    const notification = typeof outer?.method === "string" ? record(outer.params) : outer
    const sessionId = string(notification?.sessionId)
    const update = record(notification?.update)
    const childId = string(update?.child_session_id) ?? string(update?.subagent_id)
    if (sessionId === undefined || update === undefined || childId === undefined) return []
    if (update.sessionUpdate === "subagent_spawned") return this.spawned(sessionId, childId, update)
    if (update.sessionUpdate !== "subagent_finished") return []
    const child = this.children.get(childId)
    const status = finishedStatus(update)
    if (child === undefined || status === undefined) return []
    return [this.event(child.rootSessionId, { status, toolCallId: child.callId })]
  }

  childEvents(
    childSessionId: string,
    events: ReadonlyArray<RuntimeEvent>
  ): ReadonlyArray<RuntimeEvent> {
    const child = this.children.get(childSessionId)
    if (child === undefined) return []
    return events.map((event) => {
      const payload = { ...record(event.payload) }
      const toolCallId = string(payload.toolCallId)
      if (toolCallId !== undefined) payload.toolCallId = `${childSessionId}:${toolCallId}`
      return {
        ...event,
        payload: { ...payload, parentToolCallId: child.callId },
        subjectId: child.rootSessionId
      }
    })
  }

  private spawned(
    sessionId: string,
    childId: string,
    update: JsonRecord
  ): ReadonlyArray<RuntimeEvent> {
    const task = this.taskForSpawn(sessionId, childId, update)
    if (task === undefined) return []
    const resumedFrom = string(update.resumed_from)
    const child = this.link(task, childId, resumedFrom)
    return [
      this.event(child.rootSessionId, { _meta: subagentMeta(child), toolCallId: child.callId })
    ]
  }

  private taskForSpawn(
    sessionId: string,
    childId: string,
    update: JsonRecord
  ): GrokTask | undefined {
    const description = string(update.description)
    const subagentType = string(update.subagent_type)
    const open = [...this.tasks.values()].filter(
      (task) => task.sessionId === sessionId && task.childId === undefined
    )
    return (
      [...this.tasks.values()].find((candidate) => candidate.childId === childId) ??
      open.find(
        (candidate) =>
          candidate.description === description &&
          (subagentType === undefined || candidate.subagentType === subagentType)
      ) ??
      open.find((candidate) => candidate.description === description) ??
      open[0]
    )
  }

  private link(task: GrokTask, childId: string, resumedFrom?: string): GrokChild {
    const existing = this.children.get(childId)
    if (existing !== undefined && task.childId === childId) return existing
    task.childId = childId
    const parent = this.children.get(task.sessionId)
    const resumed = resumedFrom === undefined ? undefined : this.children.get(resumedFrom)
    const child: GrokChild = {
      callId: parent === undefined ? task.callId : `${task.sessionId}:${task.callId}`,
      continues: resumedFrom !== undefined,
      rootSessionId: parent?.rootSessionId ?? task.sessionId,
      taskId: resumed?.taskId ?? resumedFrom ?? childId
    }
    this.children.set(childId, child)
    return child
  }

  private messageToSubagent(update: JsonRecord, input: JsonRecord | undefined): JsonRecord {
    const subagentId = string(input?.subagent_id)
    const child = subagentId === undefined ? undefined : this.children.get(subagentId)
    if (input === undefined || subagentId === undefined) return update
    return {
      ...update,
      _meta: {
        ...record(update._meta),
        codevisorSubagent: { taskId: child?.taskId ?? subagentId }
      },
      rawInput: { ...input, ...(string(input.text) === undefined ? {} : { message: input.text }) }
    }
  }

  private event(sessionId: string, update: JsonRecord): RuntimeEvent {
    return {
      kind: "session.output",
      subjectId: sessionId,
      payload: { sessionUpdate: "tool_call_update", ...update }
    }
  }
}

const isTaskCall = (
  update: JsonRecord,
  input: JsonRecord | undefined,
  tool: JsonRecord | undefined
): boolean =>
  tool?.kind === "task" ||
  input?.variant === "Task" ||
  (update.sessionUpdate === "tool_call" && TASK_TOOL_NAMES.has(String(update.title)))

const backgroundSubagentId = (output: JsonRecord | undefined): string | undefined => {
  if (output?.type !== "Text" || typeof output.text !== "string") return undefined
  return /^subagent_id:\s*(\S+)/m.exec(output.text)?.[1]
}

const learnTask = (task: GrokTask, input: JsonRecord): void => {
  const description = string(input.description)
  const prompt = string(input.prompt)
  const subagentType = string(input.subagent_type)
  if (description !== undefined) task.description = description
  if (prompt !== undefined) task.prompt = prompt
  if (subagentType !== undefined) task.subagentType = subagentType
}

const taskKey = (sessionId: string, toolCallId: string): string => `${sessionId}\u0000${toolCallId}`

const taskInput = (task: GrokTask): JsonRecord => ({
  ...(task.description === undefined ? {} : { description: task.description }),
  ...(task.prompt === undefined ? {} : { prompt: task.prompt }),
  ...(task.subagentType === undefined ? {} : { subagent_type: task.subagentType })
})

const subagentMeta = (child: GrokChild): JsonRecord => ({
  codevisorSubagent: {
    taskId: child.taskId,
    ...(child.continues ? { continues: true } : {})
  }
})
