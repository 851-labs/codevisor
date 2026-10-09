import type { RuntimeEvent } from "@codevisor/agent-runtime"

/// The updates of a subagent's own session that belong in its thread; the
/// rest (its prompt echo, plan, usage) describe the child session itself.
const CHILD_THREAD_UPDATES = new Set([
  "agent_message_chunk",
  "agent_thought_chunk",
  "tool_call",
  "tool_call_update"
])

/// The Task tool's names: its wire name and its aliases.
const TASK_TOOL_NAMES = new Set(["task", "Task", "spawn_subagent"])

type JsonRecord = Record<string, unknown>

const record = (value: unknown): JsonRecord | undefined =>
  typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as JsonRecord)
    : undefined

const string = (value: unknown): string | undefined =>
  typeof value === "string" && value.length > 0 ? value : undefined

interface GrokTask {
  readonly callId: string
  /// The session whose turn made the call: the chat's, or (nested) a
  /// subagent's own.
  readonly sessionId: string
  description?: string
  prompt?: string
  subagentType?: string
  childId?: string
}

interface GrokChild {
  /// The chat session the child's work is shown in.
  readonly rootSessionId: string
  /// The agent call it streams under, as the chat sees it.
  readonly callId: string
  /// Ties the runs of one subagent (a resumed one continues the original).
  readonly taskId: string
  readonly continues: boolean
}

/// Shows Grok Build subagents as agents. Its Task tool call becomes an
/// "agent" call, the subagent's own session (which Grok streams on the same
/// connection) nests into it (`parentToolCallId`), and `subagent_finished`
/// settles it — Task calls run in the background by default, returning
/// before the subagent is done.
///
/// Grok doesn't say which call spawned a subagent, so `subagent_spawned` is
/// matched to its session's open Task call by description and type, and the
/// subagent id a call reports when it returns confirms the match.
export class GrokSubagents {
  /// Task calls by session and call id.
  private readonly tasks = new Map<string, GrokTask>()
  private readonly children = new Map<string, GrokChild>()

  isChildSession(sessionId: string): boolean {
    return this.children.has(sessionId)
  }

  /// The session an `x.ai` extension notification is about.
  sessionOf(params: unknown): string | undefined {
    const outer = record(params)
    const notification = typeof outer?.method === "string" ? record(outer.params) : outer
    return string(notification?.sessionId)
  }

  isThreadUpdate(update: JsonRecord): boolean {
    return CHILD_THREAD_UPDATES.has(String(update.sessionUpdate))
  }

  /// Grok's Task call as an agent call, and a message sent to a subagent tied
  /// to it; anything else unchanged.
  mapToolUpdate(sessionId: string, update: JsonRecord): JsonRecord {
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
    // Without its input yet it stays inputless, so clients show it starting.
    if (Object.keys(taskInput(task)).length === 0) delete mapped.rawInput
    if (task.description !== undefined) mapped.title = task.description

    const output = record(update.rawOutput)
    const reported = string(output?.subagent_id) ?? backgroundSubagentId(output)
    if (reported !== undefined) this.link(task, reported)
    // A background Task call returns as soon as its subagent starts: the
    // subagent settles it when it finishes.
    if (update.status === "completed" && output?.type === "Text") delete mapped.status
    const child = task.childId === undefined ? undefined : this.children.get(task.childId)
    if (child !== undefined) mapped._meta = { ...record(update._meta), ...subagentMeta(child) }
    return mapped
  }

  /// `x.ai/session_notification` (and its replay, `x.ai/session/update`):
  /// a subagent spawned or finished.
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
    const status =
      update.status === "completed"
        ? "completed"
        : update.status === "cancelled"
          ? "cancelled"
          : update.status === "failed"
            ? "failed"
            : undefined
    if (child === undefined || status === undefined) return []
    return [this.event(child.rootSessionId, { status, toolCallId: child.callId })]
  }

  /// A child session's events, moved into the chat under its agent's call.
  /// Its tool call ids are namespaced by session so runs never collide.
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

  private spawned(
    sessionId: string,
    childId: string,
    update: JsonRecord
  ): ReadonlyArray<RuntimeEvent> {
    const description = string(update.description)
    const subagentType = string(update.subagent_type)
    const open = [...this.tasks.values()].filter(
      (task) => task.sessionId === sessionId && task.childId === undefined
    )
    const task =
      [...this.tasks.values()].find((candidate) => candidate.childId === childId) ??
      open.find(
        (candidate) =>
          candidate.description === description &&
          (subagentType === undefined || candidate.subagentType === subagentType)
      ) ??
      open.find((candidate) => candidate.description === description) ??
      open[0]
    if (task === undefined) return []
    const resumedFrom = string(update.resumed_from)
    const child = this.link(task, childId, resumedFrom)
    return [
      this.event(child.rootSessionId, { _meta: subagentMeta(child), toolCallId: child.callId })
    ]
  }

  private link(task: GrokTask, childId: string, resumedFrom?: string): GrokChild {
    const existing = this.children.get(childId)
    if (existing !== undefined && task.childId === childId) return existing
    task.childId = childId
    // A subagent spawned by a subagent nests under that one's call.
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

  /// `send_subagent_message`: tied to the subagent it messages, with its text
  /// as the message, so the subagent's thread shows it.
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

/// A background Task call's text result names its subagent
/// ("subagent_id: <id>").
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

/// Ties every run of one subagent together, so opening any of its calls
/// shows its whole history.
const subagentMeta = (child: GrokChild): JsonRecord => ({
  codevisorSubagent: {
    taskId: child.taskId,
    ...(child.continues ? { continues: true } : {})
  }
})
