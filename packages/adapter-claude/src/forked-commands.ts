import type { SDKMessage } from "@anthropic-ai/claude-agent-sdk"

import { isRecord } from "./internal.js"
import type { ClaudeSession, ForkedCommand } from "./session.js"
import { ensureObservedTurnStarted } from "./turn-lifecycle.js"

const FORKED_COMMAND_PREFIX = "forked-command-"

const MIRROR_POLL_MS = 500

type TaskStarted = Extract<SDKMessage, { type: "system"; subtype: "task_started" }>
type ThreadMessage = Extract<SDKMessage, { type: "assistant" | "stream_event" | "user" }>

const mirroredMessages = new WeakSet<object>()

export const forkedCommandRowId = (session: ClaudeSession, taskId: string): string | undefined => {
  for (const [parentId, command] of session.forkedCommands) {
    if (command.taskId === taskId) return parentId
  }
  return undefined
}

export const startForkedCommand = (
  session: ClaudeSession,
  message: TaskStarted,
  show: (message: SDKMessage) => void
): void => {
  if (
    message.tool_use_id !== undefined ||
    message.subagent_type === undefined ||
    !message.description.startsWith("/")
  ) {
    return
  }
  const name = message.description.slice(1)
  const parentId = `${FORKED_COMMAND_PREFIX}${name}`
  if (session.forkedCommands.has(parentId)) return
  const command: ForkedCommand = {
    description: message.description,
    failed: false,
    mirror: { offset: 0, path: undefined, show, shown: false, timer: undefined },
    prompt: message.prompt,
    subagentType: message.subagent_type,
    taskId: message.task_id
  }
  openRow(session, parentId, command)
  const timer = setInterval(() => mirror(session, parentId, command), MIRROR_POLL_MS)
  timer.unref?.()
  command.mirror!.timer = timer
}

export const acceptForkedCommandMessage = (
  session: ClaudeSession,
  message: ThreadMessage
): boolean => {
  const parentId = message.parent_tool_use_id
  if (
    mirroredMessages.has(message) ||
    parentId === null ||
    !parentId.startsWith(FORKED_COMMAND_PREFIX)
  ) {
    return true
  }
  const command = session.forkedCommands.get(parentId)
  if (command === undefined) {
    openRow(session, parentId, {
      description: `/${parentId.slice(FORKED_COMMAND_PREFIX.length)}`,
      failed: false,
      mirror: undefined,
      prompt: undefined,
      subagentType: undefined,
      taskId: undefined
    })
    return true
  }
  finishMirror(session, parentId, command)
  return command.mirror?.shown !== true
}

const FAILED_TASK_STATUSES = new Set(["failed", "killed", "stopped"])

export const finishForkedCommand = (
  session: ClaudeSession,
  taskId: string,
  status: string
): void => {
  const parentId = forkedCommandRowId(session, taskId)
  if (parentId === undefined) return
  const command = session.forkedCommands.get(parentId)!
  if (FAILED_TASK_STATUSES.has(status)) command.failed = true
  finishMirror(session, parentId, command)
}

export const settleForkedCommands = (session: ClaudeSession, report?: string): boolean => {
  let reported = false
  for (const [parentId, command] of session.forkedCommands) {
    if (report !== undefined && !command.failed) reported = true
    finishMirror(session, parentId, command)
    session.openToolCalls.delete(parentId)
    if (report !== undefined && report.trim() !== session.subagentLastTexts.get(parentId)?.trim()) {
      void session.emit({
        kind: "session.output",
        payload: {
          content: { text: report, type: "text" },
          messageId: `agent-report:${parentId}`,
          parentToolCallId: parentId,
          sessionUpdate: "agent_message_chunk"
        },
        subjectId: session.key
      })
    }
    void session.emit({
      kind: "session.output",
      payload: {
        sessionUpdate: "tool_call_update",
        status: command.failed ? "failed" : "completed",
        toolCallId: parentId
      },
      subjectId: session.key
    })
  }
  session.forkedCommands.clear()
  return reported
}

const openRow = (session: ClaudeSession, parentId: string, command: ForkedCommand): void => {
  session.forkedCommands.set(parentId, command)
  session.openToolCalls.add(parentId)
  void ensureObservedTurnStarted(session)
  void session.emit({
    kind: "session.output",
    payload: {
      ...(command.taskId === undefined
        ? {}
        : { _meta: { codevisorSubagent: { taskId: command.taskId } } }),
      kind: "agent",
      rawInput: {
        description: command.description,
        ...(command.prompt === undefined ? {} : { prompt: command.prompt }),
        ...(command.subagentType === undefined ? {} : { subagent_type: command.subagentType })
      },
      sessionUpdate: "tool_call",
      status: "in_progress",
      title: `Skill: ${command.description}`,
      toolCallId: parentId
    },
    subjectId: session.key
  })
}

const mirror = (session: ClaudeSession, parentId: string, command: ForkedCommand): void => {
  const state = command.mirror
  if (state?.timer === undefined) return
  if (session.retired || session.forkedCommands.get(parentId) !== command) {
    clearInterval(state.timer)
    state.timer = undefined
    return
  }
  if (command.taskId === undefined) return
  state.path ??= session.subagentTranscripts.locate(session.sdkSessionId, command.taskId)
  if (state.path === undefined) return
  const { text, offset } = session.subagentTranscripts.readLines(state.path, state.offset)
  state.offset = offset
  for (const line of text.split("\n")) {
    const message = threadMessage(line, parentId, session.sdkSessionId)
    if (message === undefined) continue
    state.shown = true
    mirroredMessages.add(message)
    state.show(message)
  }
}

const finishMirror = (session: ClaudeSession, parentId: string, command: ForkedCommand): void => {
  const state = command.mirror
  if (state?.timer === undefined) return
  mirror(session, parentId, command)
  clearInterval(state.timer)
  state.timer = undefined
}

const threadMessage = (
  line: string,
  parentId: string,
  sessionId: string
): SDKMessage | undefined => {
  if (line.trim() === "") return undefined
  let entry: unknown
  try {
    entry = JSON.parse(line)
  } catch {
    return undefined
  }
  if (!isRecord(entry) || (entry.type !== "user" && entry.type !== "assistant")) return undefined
  if (!isRecord(entry.message)) return undefined
  return {
    message: entry.message,
    parent_tool_use_id: parentId,
    session_id: sessionId,
    type: entry.type,
    ...(typeof entry.uuid === "string" ? { uuid: entry.uuid } : {}),
    ...(entry.toolUseResult === undefined ? {} : { tool_use_result: entry.toolUseResult })
  } as unknown as SDKMessage
}
