import type { SDKMessage } from "@anthropic-ai/claude-agent-sdk"
import { handleSystemMessage } from "./background-tasks.js"
import { authoritativeStatsFromInput, maybeEmitStreamStats } from "./diff-stats.js"
import { isRecord } from "./internal.js"
import type { ClaudeSession } from "./session.js"
import {
  applyTaskCreate,
  applyTaskUpdate,
  emitPlanUpdate,
  emitTaskPlanUpdate,
  taskIdFromCreateResult
} from "./tasks.js"
import {
  finishedToolTitle,
  sourcesContent,
  toolKind,
  toolTitle,
  webSearchSources
} from "./tool-presentation.js"
import { ensureObservedTurnStarted } from "./turn-lifecycle.js"
import { handleResult } from "./turn-recovery.js"
import {
  claudeContextUsageFromAssistant,
  detectApiErrorMessage,
  detectUsageLimitMessage
} from "./usage.js"

/// Snapshot-style tools rendered as plans instead of tool calls: TodoWrite
/// carries the step checklist (`input.todos`), ExitPlanMode the plan-mode plan
/// document (`input.plan`).
const PLAN_TOOLS = new Set(["TodoWrite", "ExitPlanMode"])

/// Newer headless Claude sessions use an incremental task API in every
/// permission mode instead of TodoWrite's full snapshots. Codevisor accumulates
/// these mutations into the same plan wire shape clients use for checklists.
const TASK_TOOLS = new Set(["TaskCreate", "TaskUpdate", "TaskList", "TaskGet"])

/// Tools whose generic tool-call lifecycle never reaches the wire: plan tools
/// and task tools surface as plan updates, AskUserQuestion as a blocking
/// `question` event handled through canUseTool.
const HIDDEN_TOOLS = new Set([...PLAN_TOOLS, ...TASK_TOOLS, "AskUserQuestion"])

// MARK: message pump

export const handleMessage = (
  session: ClaudeSession,
  message: SDKMessage,
  readFile: (path: string) => string | undefined
): void => {
  switch (message.type) {
    case "stream_event":
      handleStreamEvent(session, message, readFile)
      break
    case "assistant": {
      const parentId = message.parent_tool_use_id ?? undefined
      if (parentId === undefined) {
        const contextUsage = claudeContextUsageFromAssistant(message.message)
        if (contextUsage !== undefined) session.latestContextUsage = contextUsage
        // Remember the SDK's per-message error (overloaded/rate_limit/… or
        // max_output_tokens) so a following error `result` can be classified
        // transient vs permanent, and a truncation can be recovered.
        const assistantError = (message as { error?: unknown }).error
        const usageLimitText = detectUsageLimitMessage(message)
        if (typeof assistantError === "string") {
          session.lastAssistantError = assistantError
          if (
            usageLimitText !== undefined &&
            (assistantError === "rate_limit" || assistantError === "billing_error")
          ) {
            session.lastUsageLimitText = usageLimitText
          }
        } else {
          if (usageLimitText !== undefined) {
            session.lastAssistantError = "rate_limit"
            session.lastUsageLimitText = usageLimitText
          }
          // Some transient failures (e.g. a 529 overload) carry no structured
          // error — the CLI renders them as an assistant text message ending on
          // a stop sequence (e.g. "API Error: 529 Overloaded …"). Detect that
          // shape so the turn retries instead of surfacing the error as if it
          // were the answer.
          const apiError = usageLimitText === undefined ? detectApiErrorMessage(message) : undefined
          if (apiError !== undefined) {
            session.lastAssistantError = "overloaded"
            session.lastErrorText = apiError
          }
        }
        void ensureObservedTurnStarted(session)
      }
      const content = message.message.content
      if (!Array.isArray(content)) break
      const inner = message.message as unknown as Record<string, unknown>
      const messageId = typeof inner.id === "string" ? inner.id : undefined
      // The CLI does not forward subagent stream events, so a subagent's prose
      // exists only here, in its consolidated assistant messages. Emit it
      // tagged with the parent tool call — unless this message DID stream
      // (older CLIs), in which case the chunks are already out and re-emitting
      // would double the text.
      const alreadyStreamed =
        parentId !== undefined &&
        messageId !== undefined &&
        session.subagentMessageIds.get(parentId) === messageId
      for (const block of content) {
        if (!isRecord(block)) continue
        if (block.type === "text" && parentId !== undefined && !alreadyStreamed) {
          const text = String(block.text ?? "")
          if (text.length === 0) continue
          void session.emit({
            kind: "session.output",
            payload: {
              content: { text, type: "text" },
              parentToolCallId: parentId,
              sessionUpdate: "agent_message_chunk",
              ...(messageId === undefined ? {} : { messageId })
            },
            subjectId: session.key
          })
        } else if (block.type === "tool_use") {
          const toolUseId = String(block.id)
          const toolName = String(block.name)
          if (PLAN_TOOLS.has(toolName)) {
            emitPlanUpdate(session, toolName, block.input)
            continue
          }
          if (TASK_TOOLS.has(toolName)) {
            session.taskToolUses.set(toolUseId, { input: block.input, name: toolName })
            continue
          }
          // AskUserQuestion surfaces as a blocking question via canUseTool.
          if (HIDDEN_TOOLS.has(toolName)) continue
          const stats = authoritativeStatsFromInput(session, toolName, block.input, readFile)
          void session.emit({
            kind: "session.output",
            payload: {
              // The streamed tool_call may never have existed for subagent
              // tools (no subagent stream events), so this update must carry
              // enough to create the call outright — including its kind.
              kind: toolKind(toolName),
              rawInput: block.input,
              sessionUpdate: "tool_call_update",
              status: "in_progress",
              title: toolTitle(toolName, block.input),
              toolCallId: toolUseId,
              ...(stats === undefined ? {} : { diffStats: stats }),
              ...(parentId === undefined ? {} : { parentToolCallId: parentId })
            },
            subjectId: session.key
          })
        }
      }
      break
    }
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
        if (parentId === undefined && String(delta.text ?? "").length > 0) {
          session.currentMessageTextStreamed = true
        }
        void session.emit({
          kind: "session.output",
          payload: {
            content: { text: String(delta.text ?? ""), type: "text" },
            sessionUpdate: "agent_message_chunk",
            ...(messageId === undefined ? {} : { messageId }),
            ...(parentId === undefined ? {} : { parentToolCallId: parentId })
          },
          subjectId: session.key
        })
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
