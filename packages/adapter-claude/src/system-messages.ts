import { randomUUID } from "node:crypto"

import type { SDKMessage } from "@anthropic-ai/claude-agent-sdk"

import {
  handleTaskNotification,
  handleTaskProgress,
  handleTaskStarted,
  handleTaskUpdated,
  replaceBackgroundTasks
} from "./background-tasks.js"
import type { ClaudeRuntimeState, ClaudeSession } from "./session.js"
import { updateClaudeCommands } from "./skills.js"
import { finishDeferredTaskResult } from "./turn-recovery.js"

type SystemMessage = Extract<SDKMessage, { type: "system" }>

type ApiRetryMessage = Extract<SystemMessage, { subtype: "api_retry" }>

type StatusMessage = Extract<SystemMessage, { subtype: "status" }>

type SessionStateMessage = Extract<SystemMessage, { subtype: "session_state_changed" }>

type CompactionStatus = "started" | "completed" | "failed"

interface InternalRetryStatus {
  readonly attempt?: number
  readonly message: string
  readonly of?: number
}

export const handleSystemMessage = (session: ClaudeSession, message: SystemMessage): void => {
  switch (message.subtype) {
    case "commands_changed":
      updateClaudeCommands(session, message.commands)
      break
    case "api_retry":
      handleApiRetry(session, message)
      break
    case "status":
      handleCompactionStatus(session, message)
      break
    case "task_started":
      handleTaskStarted(session, message)
      break
    case "task_progress":
      handleTaskProgress(session, message)
      break
    case "task_updated":
      handleTaskUpdated(session, message)
      break
    case "task_notification":
      handleTaskNotification(session, message)
      break
    case "background_tasks_changed":
      replaceBackgroundTasks(session, message.tasks)
      break
    case "session_state_changed":
      emitRuntimeState(session, message)
      break
    default:
      break
  }
}

const handleApiRetry = (session: ClaudeSession, message: ApiRetryMessage): void => {
  if (!session.turnActive) return
  if (message.error === "authentication_failed") {
    interruptOnAuthenticationFailure(session)
    return
  }

  emitInternalRetry(session, message)
}

const interruptOnAuthenticationFailure = (session: ClaudeSession): void => {
  if (session.lastAssistantError === "authentication_failed") return

  session.lastAssistantError = "authentication_failed"
  void session.q.interrupt().catch(() => undefined)
}

const emitInternalRetry = (session: ClaudeSession, message: ApiRetryMessage): void => {
  const retry = claudeInternalRetryStatus(message)
  void session.emit({
    kind: "session.updated",
    payload: { retrying: retry, turnId: session.turnId },
    subjectId: session.key
  })
}

const claudeInternalRetryStatus = (message: ApiRetryMessage): InternalRetryStatus => {
  const status = message.error_status ?? undefined
  const retryMessage = retryReason(status, message)
  return {
    ...(message.attempt > 0 ? { attempt: message.attempt } : {}),
    message: retryMessage,
    ...(message.max_retries > 0 ? { of: message.max_retries } : {})
  }
}

const retryReason = (status: number | undefined, message: ApiRetryMessage): string => {
  if (status === 529 || message.error === "overloaded") return "Claude is overloaded, retrying"
  if (status === 429 || message.error === "rate_limit")
    return "Claude is temporarily rate limited, retrying"
  if (status !== undefined && status >= 500) return "Claude returned a server error, retrying"
  return "Claude connection was interrupted, retrying"
}

const handleCompactionStatus = (session: ClaudeSession, message: StatusMessage): void => {
  const status = compactionStatus(message)
  if (status === undefined) return

  const compactionId = compactionIdFor(session, status)
  emitCompaction(session, compactionId, status)
  if (status !== "started") session.activeContextCompactionId = undefined
}

const compactionStatus = (message: StatusMessage): CompactionStatus | undefined => {
  if (message.compact_result === "success") return "completed"
  if (message.compact_result === "failed") return "failed"
  if (message.status === "compacting") return "started"
  return undefined
}

const compactionIdFor = (session: ClaudeSession, status: CompactionStatus): string => {
  if (status === "started" || session.activeContextCompactionId === undefined) {
    session.activeContextCompactionId = randomUUID()
  }
  return session.activeContextCompactionId
}

const emitCompaction = (
  session: ClaudeSession,
  compactionId: string,
  status: CompactionStatus
): void => {
  void session.emit({
    kind: "session.output",
    payload: {
      sessionUpdate: "context_compaction",
      compactionId,
      status
    },
    subjectId: session.key
  })
}

export const reportRuntimeState = (session: ClaudeSession, state: ClaudeRuntimeState): void => {
  session.runtimeState = state
  void session.emit({
    kind: "session.updated",
    payload: { runtimeState: state },
    subjectId: session.key
  })
}

const emitRuntimeState = (session: ClaudeSession, message: SessionStateMessage): void => {
  reportRuntimeState(session, message.state)
  if (message.state === "idle") finishDeferredTaskResult(session)
}
