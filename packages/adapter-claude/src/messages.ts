import type { SDKMessage } from "@anthropic-ai/claude-agent-sdk"

import { handleAssistantMessage, messageProse } from "./assistant-messages.js"
import { handleSystemMessage } from "./background-tasks.js"
import { acceptForkedCommandMessage, startForkedCommand } from "./forked-commands.js"
import { isRecord } from "./internal.js"
import { HIDDEN_TOOLS } from "./message-tool-policy.js"
import type { ClaudeSession, ClaudeTaskToolUse } from "./session.js"
import { attachSkillText, skillResultMeta } from "./skill-tool.js"
import { handleStreamEvent } from "./stream-events.js"
import {
  applyTaskCreate,
  applyTaskUpdate,
  emitTaskPlanUpdate,
  taskIdFromCreateResult
} from "./tasks.js"
import { finishedToolTitle, sourcesContent, webSearchSources } from "./tool-presentation.js"
import { handleResult } from "./turn-recovery.js"

export const handleMessage = (
  session: ClaudeSession,
  message: SDKMessage,
  readFile: (path: string) => string | undefined
): void => {
  if (
    (message.type === "assistant" || message.type === "stream_event" || message.type === "user") &&
    !acceptForkedCommandMessage(session, message)
  ) {
    return
  }
  switch (message.type) {
    case "stream_event":
      handleStreamEvent(session, message, readFile)
      break
    case "assistant":
      handleAssistantMessage(session, message, readFile)
      break
    case "user": {
      const content = message.message.content
      if (!Array.isArray(content)) break
      if (message.isSynthetic === true && attachSkillText(session, content)) break
      for (const block of content) {
        if (isRecord(block) && block.type === "tool_result") {
          handleToolResult(session, message, block)
        }
      }
      break
    }
    case "rate_limit_event":
      session.latestRateLimitInfo = message.rate_limit_info
      break
    case "result":
      handleResult(session, message)
      break
    case "system":
      if (message.subtype === "task_started") {
        startForkedCommand(session, message, (mirrored) =>
          handleMessage(session, mirrored, readFile)
        )
      }
      handleSystemMessage(session, message)
      break
    default:
      break
  }
}

type UserMessage = Extract<SDKMessage, { type: "user" }>
type ToolResult = Extract<
  Exclude<UserMessage["message"]["content"], string>[number],
  { type: "tool_result" }
>

const handleToolResult = (
  session: ClaudeSession,
  message: UserMessage,
  block: ToolResult
): void => {
  const toolUseId = block.tool_use_id
  session.openToolCalls.delete(toolUseId)
  const accumulator = session.accumulators.get(toolUseId)
  const taskToolUse = session.taskToolUses.get(toolUseId)
  session.taskToolUses.delete(toolUseId)
  if (taskToolUse !== undefined) {
    applyTaskToolResult(session, taskToolUse, block)
    return
  }
  if (accumulator !== undefined && HIDDEN_TOOLS.has(accumulator.toolName)) return
  emitSubagentReport(session, toolUseId, message.tool_use_result)
  const doneTitle =
    accumulator !== undefined && accumulator.titledPath !== undefined
      ? finishedToolTitle(accumulator.toolName, accumulator.titledPath)
      : undefined
  const sources = block.is_error === true ? [] : webSearchSources(block.content)
  const skill = skillResultMeta(session, toolUseId, block.is_error === true)
  void session.emit({
    kind: "session.output",
    payload: {
      rawOutput: block.content,
      sessionUpdate: "tool_call_update",
      status: block.is_error === true ? "failed" : "completed",
      toolCallId: toolUseId,
      ...(doneTitle === undefined ? {} : { title: doneTitle }),
      ...(sources.length === 0 ? {} : { content: sourcesContent(sources) }),
      ...skill
    },
    subjectId: session.key
  })
}

const applyTaskToolResult = (
  session: ClaudeSession,
  taskToolUse: ClaudeTaskToolUse,
  block: ToolResult
): void => {
  if (block.is_error === true) return
  let changed = false
  if (taskToolUse.name === "TaskCreate") {
    changed = applyTaskCreate(
      session.tasks,
      taskIdFromCreateResult(block.content),
      taskToolUse.input
    )
  } else if (taskToolUse.name === "TaskUpdate") {
    changed = applyTaskUpdate(session.tasks, taskToolUse.input)
  }
  if (changed) emitTaskPlanUpdate(session)
}

const emitSubagentReport = (session: ClaudeSession, toolUseId: string, result: unknown): void => {
  const lastText = session.subagentLastTexts.get(toolUseId)
  session.subagentLastTexts.delete(toolUseId)
  const report = completedAgentReport(result)
  if (report === undefined || report.trim() === lastText?.trim()) return
  void session.emit({
    kind: "session.output",
    payload: {
      content: { text: report, type: "text" },
      messageId: `agent-report:${toolUseId}`,
      parentToolCallId: toolUseId,
      sessionUpdate: "agent_message_chunk"
    },
    subjectId: session.key
  })
}

const completedAgentReport = (result: unknown): string | undefined => {
  if (!isRecord(result) || result.status !== "completed" || typeof result.agentId !== "string") {
    return undefined
  }
  if (!Array.isArray(result.content)) return undefined
  return messageProse(result.content)
}
