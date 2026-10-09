import type { SDKMessage } from "@anthropic-ai/claude-agent-sdk"

import { isRecord } from "./internal.js"
import type { ClaudeSession, ForkedCommand } from "./session.js"
import { ensureObservedTurnStarted } from "./turn-lifecycle.js"

/// Claude Code runs a forked slash command (a `context: fork` skill such as
/// `/code-review`) as a subagent whose messages name a parent that no tool
/// call ever opened: `forked-command-<name>`. In SDK mode the fork blocks the
/// turn, the CLI holds every message of its thread until it ends, and its
/// report comes back as one top-level assistant message the CLI writes
/// itself. Codevisor opens a real agent call for that parent when the fork
/// starts, mirrors the thread live from the transcript the CLI writes as the
/// fork runs, and settles the call when the report arrives.
const FORKED_COMMAND_PREFIX = "forked-command-"

/// How often a running fork's transcript is read for new messages.
const MIRROR_POLL_MS = 500

type TaskStarted = Extract<SDKMessage, { type: "system"; subtype: "task_started" }>
type ThreadMessage = Extract<SDKMessage, { type: "assistant" | "stream_event" | "user" }>

/// Messages replayed from a fork's transcript, told apart from the CLI's
/// end-of-run copy of the same thread.
const mirroredMessages = new WeakSet<object>()

/// The row of the forked command running as task `taskId`.
export const forkedCommandRowId = (session: ClaudeSession, taskId: string): string | undefined => {
  for (const [parentId, command] of session.forkedCommands) {
    if (command.taskId === taskId) return parentId
  }
  return undefined
}

/// A subagent started by a slash command rather than a tool call is a forked
/// command; its task is described by the command (`/code-review`). Its row
/// opens now, under the parent its messages will name, and its transcript is
/// mirrored into it through `show` while it runs.
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

/// Whether a thread message should be shown. Opens the row of a forked command
/// whose start was never seen, and drops the CLI's end-of-run copy of a
/// thread already mirrored from its transcript.
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
  // The fork has ended: whatever the transcript still holds comes first.
  finishMirror(session, parentId, command)
  return command.mirror?.shown !== true
}

const FAILED_TASK_STATUSES = new Set(["failed", "killed", "stopped"])

/// A forked command's task settled: its transcript is complete, and a failure
/// is recorded for its row.
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

/// Settles every open forked command. A report, when given, also ends the
/// command's thread unless the thread already ends with it. Returns whether a
/// command completed with that report, which Claude then answers with.
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
  // Open like any tool call, so a turn that ends before the report settles it.
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

/// Shows the transcript lines written since the last read.
const mirror = (session: ClaudeSession, parentId: string, command: ForkedCommand): void => {
  const state = command.mirror
  if (state?.timer === undefined) return
  // A settled or abandoned fork stops reading.
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

/// Reads the rest of a fork's transcript once, then stops reading it.
const finishMirror = (session: ClaudeSession, parentId: string, command: ForkedCommand): void => {
  const state = command.mirror
  if (state?.timer === undefined) return
  mirror(session, parentId, command)
  clearInterval(state.timer)
  state.timer = undefined
}

/// One transcript line as the thread message the SDK would have delivered.
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
