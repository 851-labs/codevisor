import type { SDKMessage } from "@anthropic-ai/claude-agent-sdk"

import { handleAssistantMessage, messageProse } from "./assistant-messages.js"
import { handleSystemMessage } from "./background-tasks.js"
import { acceptForkedCommandMessage, startForkedCommand } from "./forked-commands.js"
import { isRecord } from "./internal.js"
import { HIDDEN_TOOLS } from "./message-tool-policy.js"
import type { ClaudeSession } from "./session.js"
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

// MARK: message pump

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
          const toolUseId = String(block.tool_use_id)
          session.openToolCalls.delete(toolUseId)
          const accumulator = session.accumulators.get(toolUseId)
          const taskToolUse = session.taskToolUses.get(toolUseId)
          session.taskToolUses.delete(toolUseId)
          if (taskToolUse !== undefined) {
            if (block.is_error !== true) {
              const changed =
                taskToolUse.name === "TaskCreate"
                  ? applyTaskCreate(
                      session.tasks,
                      taskIdFromCreateResult(block.content),
                      taskToolUse.input
                    )
                  : taskToolUse.name === "TaskUpdate"
                    ? applyTaskUpdate(session.tasks, taskToolUse.input)
                    : false
              if (changed) emitTaskPlanUpdate(session)
            }
            continue
          }
          // Plan tools have no tool-call lifecycle on the wire — their result
          // is the plan/plan_document update already emitted.
          if (accumulator !== undefined && HIDDEN_TOOLS.has(accumulator.toolName)) continue
          emitSubagentReport(session, toolUseId, message.tool_use_result)
          const doneTitle =
            accumulator !== undefined && accumulator.titledPath !== undefined
              ? finishedToolTitle(accumulator.toolName, accumulator.titledPath)
              : undefined
          // WebSearch's result carries the source links; surface them as
          // resource_link content so the tool card shows a tappable sources
          // list (self-gating: only web-search results parse to sources).
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
      }
      break
    }
    case "rate_limit_event":
      // This is subscription usage state, distinct from a transient HTTP 429.
      // Retain it so a following `rate_limit` result can stop immediately when
      // Claude says the account's allowance is genuinely exhausted.
      session.latestRateLimitInfo = message.rate_limit_info
      break
    case "result":
      handleResult(session, message)
      break
    case "system":
      // A forked command's row opens before its task is recorded, so the
      // task can name it.
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

/// The CLI never forwards a subagent's final message: it reaches the parent
/// only as the Agent call's result. Emit that report as the subagent's closing
/// prose so its thread ends with its answer — unless the thread already does
/// (a CLI that forwards the message).
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

/// The final text of a finished foreground agent (the SDK's `AgentOutput`
/// with status "completed"). Background launches report later, elsewhere.
const completedAgentReport = (result: unknown): string | undefined => {
  if (!isRecord(result) || result.status !== "completed" || typeof result.agentId !== "string") {
    return undefined
  }
  if (!Array.isArray(result.content)) return undefined
  return messageProse(result.content)
}
