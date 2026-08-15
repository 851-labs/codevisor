import { isRecord } from "./internal.js"
import type { ClaudeSession, ClaudeTaskEntry, ClaudeTaskState } from "./session.js"

const PLAN_ENTRY_STATUSES = new Set(["pending", "in_progress", "completed"])

/// Maps TodoWrite's todos into wire plan entries. Lenient: malformed todos
/// are skipped, unknown statuses degrade to pending. Priority is fixed at
/// "medium" — Claude todos carry no priority (mirrors claude-agent-acp).
const planEntriesFromTodos = (
  todos: ReadonlyArray<unknown>
): Array<{ content: string; priority: string; status: string }> =>
  todos.flatMap((todo) => {
    if (!isRecord(todo) || typeof todo.content !== "string" || todo.content.length === 0) {
      return []
    }
    return [
      {
        content: todo.content,
        priority: "medium",
        status:
          typeof todo.status === "string" && PLAN_ENTRY_STATUSES.has(todo.status)
            ? todo.status
            : "pending"
      }
    ]
  })

const planEntriesFromTasks = (
  tasks: ClaudeTaskState
): Array<{ content: string; priority: string; status: string }> =>
  [...tasks.values()].map((task) => ({
    content: task.subject,
    priority: "medium",
    status: task.status
  }))

export const taskIdFromCreateResult = (content: unknown): string | undefined => {
  const parseText = (text: string): string | undefined => {
    try {
      const parsed = JSON.parse(text) as unknown
      if (isRecord(parsed) && isRecord(parsed.task) && typeof parsed.task.id === "string") {
        return parsed.task.id
      }
    } catch {
      // Claude Code currently renders this as "Task #1 created successfully".
    }
    return /^Task #([^\s]+) created successfully\b/.exec(text)?.[1]
  }

  if (typeof content === "string") return parseText(content)
  if (!Array.isArray(content)) return undefined
  for (const block of content) {
    if (!isRecord(block) || block.type !== "text" || typeof block.text !== "string") continue
    const taskId = parseText(block.text)
    if (taskId !== undefined) return taskId
  }
  return undefined
}

export const applyTaskCreate = (
  tasks: ClaudeTaskState,
  taskId: string | undefined,
  input: unknown
): boolean => {
  if (taskId === undefined || !isRecord(input) || typeof input.subject !== "string") return false
  if (tasks.has(taskId)) return false
  tasks.set(taskId, {
    subject: input.subject,
    status: "pending",
    ...(typeof input.activeForm === "string" ? { activeForm: input.activeForm } : {}),
    ...(typeof input.description === "string" ? { description: input.description } : {})
  })
  return true
}

export const applyTaskUpdate = (tasks: ClaudeTaskState, input: unknown): boolean => {
  if (!isRecord(input) || typeof input.taskId !== "string") return false
  if (input.status === "deleted") return tasks.delete(input.taskId)

  const existing = tasks.get(input.taskId)
  const subject = typeof input.subject === "string" ? input.subject : existing?.subject
  if (subject === undefined) return false
  const status =
    input.status === "pending" || input.status === "in_progress" || input.status === "completed"
      ? input.status
      : (existing?.status ?? "pending")
  const next: ClaudeTaskEntry = {
    subject,
    status,
    ...(typeof input.activeForm === "string"
      ? { activeForm: input.activeForm }
      : existing?.activeForm === undefined
        ? {}
        : { activeForm: existing.activeForm }),
    ...(typeof input.description === "string"
      ? { description: input.description }
      : existing?.description === undefined
        ? {}
        : { description: existing.description })
  }
  if (
    existing?.subject === next.subject &&
    existing.status === next.status &&
    existing.activeForm === next.activeForm &&
    existing.description === next.description
  ) {
    return false
  }
  tasks.set(input.taskId, next)
  return true
}

/// Emits the plan-shaped update for a plan tool's authoritative input:
/// TodoWrite → a full-snapshot step checklist (`plan`), ExitPlanMode → the
/// plan-mode plan document (`plan_document`). Malformed input emits nothing.
export const emitPlanUpdate = (session: ClaudeSession, toolName: string, input: unknown): void => {
  if (toolName === "TodoWrite") {
    if (!isRecord(input) || !Array.isArray(input.todos)) return
    void session.emit({
      kind: "session.output",
      payload: { entries: planEntriesFromTodos(input.todos), sessionUpdate: "plan" },
      subjectId: session.key
    })
    return
  }
  // ExitPlanMode: the plan markdown is the tool input's `plan` field.
  if (!isRecord(input) || typeof input.plan !== "string" || input.plan.length === 0) return
  void session.emit({
    kind: "session.output",
    payload: { markdown: input.plan, sessionUpdate: "plan_document" },
    subjectId: session.key
  })
}

export const emitTaskPlanUpdate = (session: ClaudeSession): void => {
  void session.emit({
    kind: "session.output",
    payload: { entries: planEntriesFromTasks(session.tasks), sessionUpdate: "plan" },
    subjectId: session.key
  })
}
