import type { SDKMessage } from "@anthropic-ai/claude-agent-sdk"
import { backgroundTerminalKey } from "@codevisor/agent-runtime"
import { randomUUID } from "node:crypto"
import { isRecord } from "./internal.js"
import type { BackgroundTaskEntry, ClaudeSession } from "./session.js"

/// Tracks the SDK's background-task lifecycle (`task_*` system messages) so
/// clients can tell "idle" apart from "turn ended, waiting on background
/// work". Every change emits a full replace-on-update snapshot.
export const handleSystemMessage = (
  session: ClaudeSession,
  message: Extract<SDKMessage, { type: "system" }>
): void => {
  switch (message.subtype) {
    case "api_retry": {
      // Claude Code retries transient API failures internally before it emits
      // the assistant/result pair that drives Codevisor's bounded outer
      // recovery. Surface that internal retry immediately instead of leaving
      // the client on a stale "Thinking..." indicator for the whole backoff.
      if (!session.turnActive) break
      const retry = claudeInternalRetryStatus(message)
      void session.emit({
        kind: "session.updated",
        payload: { retrying: retry, turnId: session.turnId },
        subjectId: session.key
      })
      break
    }
    case "status": {
      const status =
        message.compact_result === "success"
          ? "completed"
          : message.compact_result === "failed"
            ? "failed"
            : message.status === "compacting"
              ? "started"
              : undefined
      if (status === undefined) break
      if (status === "started" || session.activeContextCompactionId === undefined) {
        session.activeContextCompactionId = randomUUID()
      }
      const compactionId = session.activeContextCompactionId
      void session.emit({
        kind: "session.output",
        payload: {
          sessionUpdate: "context_compaction",
          compactionId,
          status
        },
        subjectId: session.key
      })
      if (status !== "started") session.activeContextCompactionId = undefined
      break
    }
    case "task_started": {
      // Ambient/housekeeping tasks should not make the chat look busy.
      if (message.skip_transcript === true) {
        session.hiddenBackgroundTaskIds.add(message.task_id)
        if (removeBackgroundTask(session, message.task_id)) emitBackgroundTasks(session)
        break
      }
      const terminalKey =
        message.tool_use_id === undefined
          ? undefined
          : session.backgroundShellKeys.get(message.tool_use_id)
      session.backgroundTasks.set(message.task_id, {
        description: message.description,
        id: message.task_id,
        status: "running",
        taskType: message.subagent_type !== undefined ? "subagent" : (message.task_type ?? "task"),
        ...(message.tool_use_id === undefined ? {} : { toolUseId: message.tool_use_id }),
        ...(terminalKey === undefined ? {} : { terminalKey })
      })
      emitBackgroundTasks(session)
      // Retitle the spawning tool call with the task's description — the most
      // reliable source, immune to the Task→Agent tool rename.
      if (message.subagent_type !== undefined && message.tool_use_id !== undefined) {
        void session.emit({
          kind: "session.output",
          payload: {
            kind: "agent",
            sessionUpdate: "tool_call_update",
            title: `Agent: ${message.description}`,
            toolCallId: message.tool_use_id
          },
          subjectId: session.key
        })
      }
      break
    }
    case "task_progress": {
      const entry = session.backgroundTasks.get(message.task_id)
      if (entry === undefined || message.summary === undefined) break
      if (entry.description === message.summary) break
      entry.description = message.summary
      emitBackgroundTasks(session)
      break
    }
    case "task_updated": {
      const status = message.patch.status
      if (status === "completed" || status === "failed" || status === "killed") {
        session.hiddenBackgroundTaskIds.delete(message.task_id)
      }
      const entry = session.backgroundTasks.get(message.task_id)
      if (entry === undefined) break
      if (status === "completed" || status === "failed" || status === "killed") {
        removeBackgroundTask(session, message.task_id)
      } else {
        if (status !== undefined) entry.status = status
        if (message.patch.description !== undefined) entry.description = message.patch.description
      }
      emitBackgroundTasks(session)
      break
    }
    case "task_notification": {
      session.hiddenBackgroundTaskIds.delete(message.task_id)
      if (removeBackgroundTask(session, message.task_id)) {
        emitBackgroundTasks(session)
      }
      break
    }
    case "background_tasks_changed": {
      replaceBackgroundTasks(session, message.tasks)
      break
    }
    case "session_state_changed": {
      // This is a turn-loop barrier, not proof that detached work has exited:
      // Claude can be idle while a background process continues. Clients pair
      // it with the normalized task snapshot and exclude terminal-backed work.
      void session.emit({
        kind: "session.updated",
        payload: { runtimeState: message.state },
        subjectId: session.key
      })
      break
    }
    default:
      break
  }
}

export const emitBackgroundTasks = (session: ClaudeSession): Promise<void> =>
  session.emit({
    kind: "session.updated",
    payload: { backgroundTasks: [...session.backgroundTasks.values()] },
    subjectId: session.key
  })

/// Reconciles the SDK's authoritative full task set while preserving richer
/// edge metadata such as tool-use attribution and Codevisor's terminal key.
/// The level signal prevents a missed task edge from wedging the busy state.
const replaceBackgroundTasks = (
  session: ClaudeSession,
  tasks: ReadonlyArray<{ task_id: string; task_type: string; description: string }>
): void => {
  const next = new Map<string, BackgroundTaskEntry>()
  for (const task of tasks) {
    if (session.hiddenBackgroundTaskIds.has(task.task_id)) continue
    const existing = session.backgroundTasks.get(task.task_id)
    next.set(task.task_id, {
      description: task.description,
      id: task.task_id,
      status: existing?.status ?? "running",
      taskType: existing?.taskType ?? task.task_type,
      ...(existing?.toolUseId === undefined ? {} : { toolUseId: existing.toolUseId }),
      ...(existing?.terminalKey === undefined ? {} : { terminalKey: existing.terminalKey })
    })
  }
  for (const [id, existing] of session.backgroundTasks) {
    if (next.has(id) || existing.toolUseId === undefined) continue
    session.backgroundShellKeys.delete(existing.toolUseId)
  }
  session.backgroundTasks.clear()
  for (const [id, task] of next) session.backgroundTasks.set(id, task)
  emitBackgroundTasks(session)
}

const removeBackgroundTask = (session: ClaudeSession, taskId: string): boolean => {
  const entry = session.backgroundTasks.get(taskId)
  if (entry === undefined) return false
  session.backgroundTasks.delete(taskId)
  if (entry.toolUseId !== undefined) {
    session.backgroundShellKeys.delete(entry.toolUseId)
  }
  return true
}

/// PreToolUse rewrite for `Bash(run_in_background: true)`: the command runs
/// under the server's background-terminal wrapper, which tees output to an
/// attachable terminal while stdout/stderr still flow to the SDK unchanged
/// (BashOutput/KillShell keep working). Foreground commands pass through.
export const wrapBackgroundBash = (
  session: ClaudeSession,
  toolInput: unknown,
  toolUseID: string,
  wrapCommand: (key: string, command: string) => string
): {
  hookSpecificOutput?: {
    hookEventName: "PreToolUse"
    updatedInput: Record<string, unknown>
  }
} => {
  if (!isRecord(toolInput)) return {}
  if (toolInput.run_in_background !== true || typeof toolInput.command !== "string") {
    return {}
  }
  const key = backgroundTerminalKey(session.key, toolUseID)
  session.backgroundShellKeys.set(toolUseID, key)
  return {
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      updatedInput: { ...toolInput, command: wrapCommand(key, toolInput.command) }
    }
  }
}

const claudeInternalRetryStatus = (
  message: Extract<SDKMessage, { subtype: "api_retry"; type: "system" }>
): { attempt?: number; message: string; of?: number } => {
  const status = message.error_status ?? undefined
  const retryMessage =
    status === 529 || message.error === "overloaded"
      ? "Claude is overloaded, retrying"
      : status === 429 || message.error === "rate_limit"
        ? "Claude is temporarily rate limited, retrying"
        : status !== undefined && status >= 500
          ? "Claude returned a server error, retrying"
          : "Claude connection was interrupted, retrying"
  return {
    ...(message.attempt > 0 ? { attempt: message.attempt } : {}),
    message: retryMessage,
    ...(message.max_retries > 0 ? { of: message.max_retries } : {})
  }
}
