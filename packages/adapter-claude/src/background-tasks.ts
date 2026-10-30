import type { SDKMessage } from "@anthropic-ai/claude-agent-sdk"

import { finishForkedCommand, forkedCommandRowId } from "./forked-commands.js"
import { isRecord } from "./internal.js"
import type { BackgroundTaskEntry, ClaudeSession } from "./session.js"
import { toolKind } from "./tool-presentation.js"

type SystemMessage = Extract<SDKMessage, { type: "system" }>

type TaskStartedMessage = Extract<SystemMessage, { subtype: "task_started" }>

type TaskProgressMessage = Extract<SystemMessage, { subtype: "task_progress" }>

type TaskUpdatedMessage = Extract<SystemMessage, { subtype: "task_updated" }>

type TaskNotificationMessage = Extract<SystemMessage, { subtype: "task_notification" }>

type SubagentLaunchMessage = TaskStartedMessage & { readonly tool_use_id: string }

type TaskStatus = TaskUpdatedMessage["patch"]["status"]

type FinishedTaskStatus = "completed" | "failed" | "killed"

const monitorToolName = "Monitor"

interface SubagentMeta {
  readonly codevisorSubagent: { readonly taskId: string }
}

interface SubagentStartUpdate {
  readonly _meta: SubagentMeta
  readonly kind?: "agent"
  readonly sessionUpdate: "tool_call_update"
  readonly title: string
  readonly toolCallId: string
}

export const emitBackgroundTasks = (session: ClaudeSession): Promise<void> =>
  session.emit({
    kind: "session.updated",
    payload: { backgroundTasks: [...session.backgroundTasks.values()].map(wireTask(session)) },
    subjectId: session.key
  })

export const handleTaskStarted = (session: ClaudeSession, message: TaskStartedMessage): void => {
  if (message.skip_transcript === true) {
    hideBackgroundTask(session, message)
    return
  }

  trackStartedTask(session, message)
  void emitBackgroundTasks(session)
  if (launchesSubagent(message)) emitSubagentStart(session, message)
}

export const handleTaskProgress = (session: ClaudeSession, message: TaskProgressMessage): void => {
  const entry = session.backgroundTasks.get(message.task_id)
  if (entry === undefined) return
  if (message.summary === undefined) return
  if (entry.description === message.summary) return

  entry.description = message.summary
  void emitBackgroundTasks(session)
}

export const handleTaskUpdated = (session: ClaudeSession, message: TaskUpdatedMessage): void => {
  const status = message.patch.status
  if (isFinishedStatus(status)) releaseFinishedTask(session, message, status)

  const entry = session.backgroundTasks.get(message.task_id)
  if (entry === undefined) return

  if (isFinishedStatus(status)) {
    removeBackgroundTask(session, message.task_id)
  } else {
    patchBackgroundTask(entry, message, status)
  }
  void emitBackgroundTasks(session)
}

export const handleTaskNotification = (
  session: ClaudeSession,
  message: TaskNotificationMessage
): void => {
  finishForkedCommand(session, message.task_id, message.status)
  session.hiddenBackgroundTaskIds.delete(message.task_id)
  if (removeBackgroundTask(session, message.task_id)) void emitBackgroundTasks(session)
}

export const replaceBackgroundTasks = (
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
      ...(existing?.startedAt === undefined ? {} : { startedAt: existing.startedAt }),
      ...(existing?.command === undefined ? {} : { command: existing.command }),
      canStop: true
    })
  }
  session.backgroundTasks.clear()
  for (const [id, task] of next) session.backgroundTasks.set(id, task)
  void emitBackgroundTasks(session)
}

const hideBackgroundTask = (session: ClaudeSession, message: TaskStartedMessage): void => {
  session.hiddenBackgroundTaskIds.add(message.task_id)
  if (removeBackgroundTask(session, message.task_id)) void emitBackgroundTasks(session)
}

const trackStartedTask = (session: ClaudeSession, message: TaskStartedMessage): void => {
  const toolUseId = message.tool_use_id ?? forkedCommandRowId(session, message.task_id)
  const command = startingCommand(session, message.tool_use_id)
  session.backgroundTasks.set(message.task_id, {
    description: message.description,
    id: message.task_id,
    status: "running",
    taskType: startedTaskType(session, message),
    ...(toolUseId === undefined ? {} : { toolUseId }),
    startedAt: new Date().toISOString(),
    ...(command === undefined ? {} : { command }),
    canStop: true
  })
}

const startingCommand = (
  session: ClaudeSession,
  toolUseId: string | undefined
): string | undefined => {
  if (toolUseId === undefined) return undefined
  const input = parsedToolInput(session.accumulators.get(toolUseId)?.json)
  return typeof input?.command === "string" ? input.command : undefined
}

const parsedToolInput = (json: string | undefined): Record<string, unknown> | undefined => {
  if (json === undefined) return undefined
  try {
    const parsed: unknown = JSON.parse(json)
    return isRecord(parsed) ? parsed : undefined
  } catch {
    return undefined
  }
}

const wireTask =
  (session: ClaudeSession) =>
  (task: BackgroundTaskEntry): BackgroundTaskEntry & { readonly hasOutput?: true } =>
    session.backgroundTaskOutputFiles.has(task.id) ? { ...task, hasOutput: true } : task

const startedTaskType = (session: ClaudeSession, message: TaskStartedMessage): string => {
  if (message.subagent_type !== undefined) return "subagent"
  if (startedByMonitorTool(session, message)) return "monitor"
  return message.task_type ?? "task"
}

const startedByMonitorTool = (session: ClaudeSession, message: TaskStartedMessage): boolean =>
  message.tool_use_id !== undefined &&
  session.accumulators.get(message.tool_use_id)?.toolName === monitorToolName

const launchesSubagent = (message: TaskStartedMessage): message is SubagentLaunchMessage =>
  message.subagent_type !== undefined && message.tool_use_id !== undefined

const emitSubagentStart = (session: ClaudeSession, message: SubagentLaunchMessage): void => {
  const subagent = { codevisorSubagent: { taskId: message.task_id } }
  void session.emit({
    kind: "session.output",
    payload: subagentStartUpdate(session, message, subagent),
    subjectId: session.key
  })
}

const subagentStartUpdate = (
  session: ClaudeSession,
  message: SubagentLaunchMessage,
  subagent: SubagentMeta
): SubagentStartUpdate => {
  if (startsNewSubagent(session, message.tool_use_id)) {
    return {
      _meta: subagent,
      kind: "agent",
      sessionUpdate: "tool_call_update",
      title: `Agent: ${message.description}`,
      toolCallId: message.tool_use_id
    }
  }
  return {
    _meta: subagent,
    sessionUpdate: "tool_call_update",
    title: `Messaged agent: ${message.description}`,
    toolCallId: message.tool_use_id
  }
}

const startsNewSubagent = (session: ClaudeSession, toolUseId: string): boolean => {
  const toolName = session.accumulators.get(toolUseId)?.toolName
  return toolName === undefined || toolKind(toolName) === "agent"
}

const isFinishedStatus = (status: TaskStatus): status is FinishedTaskStatus =>
  status === "completed" || status === "failed" || status === "killed"

const releaseFinishedTask = (
  session: ClaudeSession,
  message: TaskUpdatedMessage,
  status: FinishedTaskStatus
): void => {
  finishForkedCommand(session, message.task_id, status)
  session.hiddenBackgroundTaskIds.delete(message.task_id)
}

const patchBackgroundTask = (
  entry: BackgroundTaskEntry,
  message: TaskUpdatedMessage,
  status: TaskStatus
): void => {
  if (status !== undefined) entry.status = status
  if (message.patch.description !== undefined) entry.description = message.patch.description
}

const removeBackgroundTask = (session: ClaudeSession, taskId: string): boolean => {
  const entry = session.backgroundTasks.get(taskId)
  if (entry === undefined) return false
  session.backgroundTasks.delete(taskId)
  session.backgroundTaskOutputFiles.delete(taskId)
  return true
}
