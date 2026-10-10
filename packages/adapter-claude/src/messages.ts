import type { SDKMessage } from "@anthropic-ai/claude-agent-sdk"

import { handleAssistantMessage, messageProse } from "./assistant-messages.js"
import { handleSystemMessage } from "./background-tasks.js"
import { maybeEmitStreamStats } from "./diff-stats.js"
import { acceptForkedCommandMessage, startForkedCommand } from "./forked-commands.js"
import { isRecord } from "./internal.js"
import { HIDDEN_TOOLS } from "./message-tool-policy.js"
import type { ClaudeSession } from "./session.js"
import {
  applyTaskCreate,
  applyTaskUpdate,
  emitTaskPlanUpdate,
  taskIdFromCreateResult
} from "./tasks.js"
import {
  finishedToolTitle,
  sourcesContent,
  toolKind,
  webSearchSources
} from "./tool-presentation.js"
import { ensureObservedTurnStarted } from "./turn-lifecycle.js"
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
          void session.emit({
            kind: "session.output",
            payload: {
              rawOutput: block.content,
              sessionUpdate: "tool_call_update",
              status: block.is_error === true ? "failed" : "completed",
              toolCallId: toolUseId,
              ...(doneTitle === undefined ? {} : { title: doneTitle }),
              ...(sources.length === 0 ? {} : { content: sourcesContent(sources) })
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

const handleStreamEvent = (
  session: ClaudeSession,
  message: Extract<SDKMessage, { type: "stream_event" }>,
  readFile: (path: string) => string | undefined
): void => {
  const event = message.event as unknown as Record<string, unknown>
  const parentId = message.parent_tool_use_id ?? undefined
  switch (event.type) {
    case "message_start": {
      const inner = event.message
      const innerId = isRecord(inner) ? String(inner.id ?? "") : undefined
      if (parentId === undefined) {
        session.currentMessageId = innerId
        session.currentMessageTextStreamed = false
        void ensureObservedTurnStarted(session)
      } else if (innerId !== undefined && innerId !== "") {
        session.subagentMessageIds.set(parentId, innerId)
      }
      break
    }
    case "content_block_start": {
      const block = event.content_block
      // Current Claude models stream thinking with its text omitted (only a
      // signature delta follows), so the block's start is the only reliable
      // thinking signal. An empty thought chunk drives the client's
      // "Thinking…" state through the otherwise silent gap; any thought text
      // that does stream still flows through `thinking_delta` below.
      if (isRecord(block) && (block.type === "thinking" || block.type === "redacted_thinking")) {
        void session.emit({
          kind: "session.output",
          payload: {
            content: { text: "", type: "text" },
            sessionUpdate: "agent_thought_chunk",
            ...(parentId === undefined ? {} : { parentToolCallId: parentId })
          },
          subjectId: session.key
        })
        break
      }
      if (isRecord(block) && block.type === "tool_use") {
        // A tool_use block starting after streamed text in the same top-level
        // message proves that text was preamble ("Let me check…"), not the
        // final answer. Retro-tag the span commentary via a zero-length chunk
        // so clients demote it out of the final-answer slot immediately
        // instead of waiting for the next text block after the tool settles.
        if (
          parentId === undefined &&
          session.currentMessageTextStreamed &&
          session.currentMessageId !== undefined &&
          session.currentMessageId !== ""
        ) {
          session.currentMessageTextStreamed = false
          void session.emit({
            kind: "session.output",
            payload: {
              content: { text: "", type: "text" },
              messageId: session.currentMessageId,
              phase: "commentary",
              sessionUpdate: "agent_message_chunk"
            },
            subjectId: session.key
          })
        }
        const toolUseId = String(block.id)
        const toolName = String(block.name)
        session.accumulators.set(toolUseId, {
          json: "",
          lastEmit: 0,
          lastStats: "",
          oldContent: undefined,
          titledPath: undefined,
          toolName
        })
        void ensureObservedTurnStarted(session)
        // Plan tools never open a tool call: they surface as plan updates
        // once the authoritative input arrives on the assistant message.
        if (HIDDEN_TOOLS.has(toolName)) break
        session.openToolCalls.add(toolUseId)
        // The model is already generating this call's input — that's work in
        // progress, and for fast tools it's most of the visible lifetime.
        void session.emit({
          kind: "session.output",
          payload: {
            kind: toolKind(toolName),
            sessionUpdate: "tool_call",
            status: "in_progress",
            title: toolName,
            toolCallId: toolUseId,
            ...(parentId === undefined ? {} : { parentToolCallId: parentId })
          },
          subjectId: session.key
        })
      }
      break
    }
    case "content_block_delta": {
      const delta = event.delta
      if (!isRecord(delta)) break
      if (delta.type === "text_delta") {
        // Subagent prose flows tagged with its parent tool call so clients can
        // nest it under the Task row instead of mixing it into the main thread.
        const messageId =
          parentId === undefined
            ? session.currentMessageId
            : session.subagentMessageIds.get(parentId)
        // A zero-length delta carries neither text nor a phase to retro-tag
        // with, so it is pure stream noise. Forwarding it created an empty
        // text span that clients counted as the final answer, retiring the
        // activity indicator with nothing to show in its place. The
        // deliberate zero-length `phase: "commentary"` retro-tag emitted on
        // tool start is a separate call and still flows.
        const text = String(delta.text ?? "")
        if (text.length > 0) {
          if (parentId === undefined) {
            session.currentMessageTextStreamed = true
          }
          void session.emit({
            kind: "session.output",
            payload: {
              content: { text, type: "text" },
              sessionUpdate: "agent_message_chunk",
              ...(messageId === undefined ? {} : { messageId }),
              ...(parentId === undefined ? {} : { parentToolCallId: parentId })
            },
            subjectId: session.key
          })
        }
      } else if (delta.type === "thinking_delta") {
        void session.emit({
          kind: "session.output",
          payload: {
            content: { text: String(delta.thinking ?? ""), type: "text" },
            sessionUpdate: "agent_thought_chunk",
            ...(parentId === undefined ? {} : { parentToolCallId: parentId })
          },
          subjectId: session.key
        })
      } else if (delta.type === "input_json_delta") {
        const toolUseId = String(event.index !== undefined ? findAccumulatorId(session, event) : "")
        const accumulator = session.accumulators.get(toolUseId)
        if (accumulator !== undefined) {
          accumulator.json += String(delta.partial_json ?? "")
          maybeEmitStreamStats(session, toolUseId, accumulator, readFile, false)
        }
      }
      break
    }
    case "content_block_stop": {
      const toolUseId = findAccumulatorId(session, event)
      const accumulator = session.accumulators.get(toolUseId)
      if (accumulator !== undefined) {
        maybeEmitStreamStats(session, toolUseId, accumulator, readFile, true)
      }
      break
    }
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

/// The Anthropic stream identifies blocks by index, not id. Content blocks
/// stream strictly sequentially per message, so the accumulator opened last
/// is the one receiving deltas.
const findAccumulatorId = (session: ClaudeSession, _event: Record<string, unknown>): string => {
  let lastKey = ""
  for (const key of session.accumulators.keys()) {
    lastKey = key
  }
  return lastKey
}
