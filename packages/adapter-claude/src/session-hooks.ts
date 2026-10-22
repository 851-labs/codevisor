import type { HookCallbackMatcher, HookEvent, HookInput } from "@anthropic-ai/claude-agent-sdk"

import { emitAuthoritativeDiff } from "./diff-stats.js"
import type { ClaudeSession, ClaudeTaskEntry, CurrentSession } from "./session.js"
import { applyTaskCreate, emitTaskPlanUpdate } from "./tasks.js"

export type ClaudeSessionHooks = Partial<Record<HookEvent, Array<HookCallbackMatcher>>>

type SessionHook = (session: ClaudeSession | undefined, hookInput: HookInput) => void

export const claudeSessionHooks = (currentSession: CurrentSession): ClaudeSessionHooks => ({
  PostToolUse: hookOn(currentSession, emitToolDiff),
  TaskCreated: hookOn(currentSession, recordCreatedTask),
  TaskCompleted: hookOn(currentSession, recordCompletedTask)
})

const hookOn = (currentSession: CurrentSession, hook: SessionHook): Array<HookCallbackMatcher> => [
  {
    hooks: [
      async (hookInput) => {
        hook(currentSession(), hookInput)
        return {}
      }
    ]
  }
]

const emitToolDiff = (session: ClaudeSession | undefined, hookInput: HookInput): void => {
  if (hookInput.hook_event_name !== "PostToolUse") return
  if (session === undefined) return

  emitAuthoritativeDiff(session, hookInput)
}

const recordCreatedTask = (session: ClaudeSession | undefined, hookInput: HookInput): void => {
  if (hookInput.hook_event_name !== "TaskCreated") return
  if (session === undefined) return

  const created = applyTaskCreate(session.tasks, hookInput.task_id, {
    description: hookInput.task_description,
    subject: hookInput.task_subject
  })
  if (created) emitTaskPlanUpdate(session)
}

const recordCompletedTask = (session: ClaudeSession | undefined, hookInput: HookInput): void => {
  if (hookInput.hook_event_name !== "TaskCompleted") return
  if (session === undefined) return

  const existing = session.tasks.get(hookInput.task_id)
  if (!isOpenTask(existing)) return

  session.tasks.set(hookInput.task_id, { ...existing, status: "completed" })
  emitTaskPlanUpdate(session)
}

const isOpenTask = (task: ClaudeTaskEntry | undefined): task is ClaudeTaskEntry =>
  task !== undefined && task.status !== "completed"
