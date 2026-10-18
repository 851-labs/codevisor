import { isRecord } from "./internal.js"
import type { ClaudeSession, ClaudeTaskEntry, ClaudeTaskState } from "./session.js"

const PLAN_ENTRY_STATUSES = new Set(["pending", "in_progress", "completed"])

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

const taskIdFromText = (text: string): string | undefined => {
  try {
    const parsed = JSON.parse(text) as unknown
    if (isRecord(parsed) && isRecord(parsed.task) && typeof parsed.task.id === "string") {
      return parsed.task.id
    }
  } catch {}
  return /^Task #([^\s]+) created successfully\b/.exec(text)?.[1]
}

export const taskIdFromCreateResult = (content: unknown): string | undefined => {
  if (typeof content === "string") return taskIdFromText(content)
  if (!Array.isArray(content)) return undefined
  for (const block of content) {
    if (!isRecord(block) || block.type !== "text" || typeof block.text !== "string") continue
    const taskId = taskIdFromText(block.text)
    if (taskId !== undefined) return taskId
  }
  return undefined
}

const taskEntry = (
  input: Record<string, unknown>,
  subject: string,
  status: ClaudeTaskEntry["status"],
  existing?: ClaudeTaskEntry
): ClaudeTaskEntry => {
  const next: { -readonly [Key in keyof ClaudeTaskEntry]: ClaudeTaskEntry[Key] } = {
    subject,
    status
  }
  if (typeof input.activeForm === "string") {
    next.activeForm = input.activeForm
  } else if (existing?.activeForm !== undefined) {
    next.activeForm = existing.activeForm
  }
  if (typeof input.description === "string") {
    next.description = input.description
  } else if (existing?.description !== undefined) {
    next.description = existing.description
  }
  return next
}

export const applyTaskCreate = (
  tasks: ClaudeTaskState,
  taskId: string | undefined,
  input: unknown
): boolean => {
  if (taskId === undefined || !isRecord(input) || typeof input.subject !== "string") return false
  if (tasks.has(taskId)) return false
  tasks.set(taskId, taskEntry(input, input.subject, "pending"))
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
  const next = taskEntry(input, subject, status, existing)
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

export const emitPlanUpdate = (session: ClaudeSession, toolName: string, input: unknown): void => {
  if (toolName !== "TodoWrite" || !isRecord(input) || !Array.isArray(input.todos)) return
  void session.emit({
    kind: "session.output",
    payload: { entries: planEntriesFromTodos(input.todos), sessionUpdate: "plan" },
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
