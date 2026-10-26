import type { SDKMessage } from "@anthropic-ai/claude-agent-sdk"

import { authoritativeStatsFromInput } from "./diff-stats.js"
import { settleForkedCommands } from "./forked-commands.js"
import { isRecord, recordOf } from "./internal.js"
import { HIDDEN_TOOLS, PLAN_TOOLS, TASK_TOOLS } from "./message-tool-policy.js"
import { claudeContextUsageFromAssistant } from "./session-context.js"
import type { ClaudeSession } from "./session.js"
import { SKILL_TOOL, skillCallMeta } from "./skill-tool.js"
import { emitPlanUpdate } from "./tasks.js"
import { toolKind, toolTitle } from "./tool-presentation.js"
import { ensureObservedTurnStarted } from "./turn-lifecycle.js"
import { detectApiErrorMessage, detectUsageLimitMessage } from "./usage.js"

type AssistantMessage = Extract<SDKMessage, { type: "assistant" }>

export const handleAssistantMessage = (
  session: ClaudeSession,
  message: AssistantMessage,
  readFile: (path: string) => string | undefined
): void => {
  const parentId = message.parent_tool_use_id ?? undefined
  const isErrorReply = observeRootAssistantStatus(session, message, parentId)
  const content = message.message.content
  if (!Array.isArray(content)) return
  const inner = recordOf(message.message)
  const messageId = typeof inner.id === "string" ? inner.id : undefined
  const alreadyStreamed =
    parentId !== undefined &&
    messageId !== undefined &&
    session.subagentMessageIds.get(parentId) === messageId
  if (parentId !== undefined) {
    const prose = messageProse(content)
    if (prose !== undefined) session.subagentLastTexts.set(parentId, prose)
  }
  emitAssistantContent(session, content, parentId, messageId, alreadyStreamed, readFile)
  emitUnannouncedAssistantReply(
    session,
    content,
    parentId,
    messageId,
    isErrorReply,
    inner.stop_reason
  )
}

const observeRootAssistantStatus = (
  session: ClaudeSession,
  message: AssistantMessage,
  parentId: string | undefined
): boolean => {
  if (parentId !== undefined) return false
  return observeAssistantStatus(session, message)
}

const observeAssistantStatus = (session: ClaudeSession, message: AssistantMessage): boolean => {
  const contextUsage = claudeContextUsageFromAssistant(message.message)
  if (contextUsage !== undefined) session.latestContextUsage = contextUsage
  const assistantError = (message as { error?: unknown }).error
  const usageLimitText = detectUsageLimitMessage(message)
  let isErrorReply: boolean
  if (typeof assistantError === "string") {
    isErrorReply = recordStructuredAssistantError(session, assistantError, usageLimitText)
    session.lastErrorText = messageProse(message.message.content)
  } else {
    isErrorReply = recordUnstructuredAssistantError(session, message, usageLimitText)
  }
  void ensureObservedTurnStarted(session)
  return isErrorReply
}

const recordStructuredAssistantError = (
  session: ClaudeSession,
  assistantError: string,
  usageLimitText: string | undefined
): boolean => {
  session.lastAssistantError = assistantError
  if (
    usageLimitText !== undefined &&
    (assistantError === "rate_limit" || assistantError === "billing_error")
  ) {
    session.lastUsageLimitText = usageLimitText
  }
  return true
}

const recordUnstructuredAssistantError = (
  session: ClaudeSession,
  message: AssistantMessage,
  usageLimitText: string | undefined
): boolean => {
  let isErrorReply = false
  if (usageLimitText !== undefined) {
    isErrorReply = true
    session.lastAssistantError = "rate_limit"
    session.lastUsageLimitText = usageLimitText
  }
  const apiError = usageLimitText === undefined ? detectApiErrorMessage(message) : undefined
  if (apiError !== undefined) {
    isErrorReply = true
    session.lastAssistantError = "overloaded"
    session.lastErrorText = apiError
  }
  return isErrorReply
}

const emitAssistantChildText = (
  session: ClaudeSession,
  block: Record<string, unknown>,
  parentId: string,
  messageId: string | undefined
): void => {
  const text = typeof block.text === "string" ? block.text : ""
  if (text.length === 0) return
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
}

const handleAssistantTool = (
  session: ClaudeSession,
  block: Record<string, unknown>,
  parentId: string | undefined,
  readFile: (path: string) => string | undefined
): void => {
  const toolUseId = String(block.id)
  const toolName = String(block.name)
  if (PLAN_TOOLS.has(toolName)) {
    emitPlanUpdate(session, toolName, block.input)
    return
  }
  if (TASK_TOOLS.has(toolName)) {
    session.taskToolUses.set(toolUseId, { input: block.input, name: toolName })
    return
  }
  if (HIDDEN_TOOLS.has(toolName)) return
  emitAssistantTool(session, toolName, toolUseId, block, parentId, readFile)
}

const emitAssistantTool = (
  session: ClaudeSession,
  toolName: string,
  toolUseId: string,
  block: Record<string, unknown>,
  parentId: string | undefined,
  readFile: (path: string) => string | undefined
): void => {
  const stats = authoritativeStatsFromInput(session, toolName, block.input, readFile)
  let skill: ReturnType<typeof skillCallMeta> | undefined
  if (toolName === SKILL_TOOL) skill = skillCallMeta(session, toolUseId, block.input, parentId)
  void session.emit({
    kind: "session.output",
    payload: {
      kind: toolKind(toolName),
      rawInput: block.input,
      sessionUpdate: "tool_call_update",
      status: "in_progress",
      title: toolTitle(toolName, block.input),
      toolCallId: toolUseId,
      ...(stats === undefined ? {} : { diffStats: stats }),
      ...skill,
      ...(parentId === undefined ? {} : { parentToolCallId: parentId })
    },
    subjectId: session.key
  })
}

const replyPhase = (stopReason: unknown): "commentary" | "final" | undefined => {
  if (stopReason === "end_turn") return "final"
  if (stopReason === "tool_use") return "commentary"
  return undefined
}

const emitAssistantReply = (
  session: ClaudeSession,
  content: ReadonlyArray<unknown>,
  messageId: string,
  stopReason: unknown
): void => {
  const phase = replyPhase(stopReason)
  const prose = messageProse(content)
  if (settleForkedCommands(session, prose)) {
    session.forkedCommandReplyPending = true
  } else if (prose !== undefined) {
    void session.emit({
      kind: "session.output",
      payload: {
        content: { text: prose, type: "text" },
        messageId,
        ...(phase === undefined ? {} : { phase }),
        sessionUpdate: "agent_message_chunk"
      },
      subjectId: session.key
    })
  }
}

export const messageProse = (content: ReadonlyArray<unknown>): string | undefined => {
  const texts = content.flatMap((block) =>
    isRecord(block) && block.type === "text" && typeof block.text === "string" && block.text !== ""
      ? [block.text]
      : []
  )
  return texts.length === 0 ? undefined : texts.join("\n\n")
}

const emitAssistantContent = (
  session: ClaudeSession,
  content: ReadonlyArray<unknown>,
  parentId: string | undefined,
  messageId: string | undefined,
  alreadyStreamed: boolean,
  readFile: (path: string) => string | undefined
): void => {
  for (const block of content) {
    if (!isRecord(block)) continue
    if (block.type === "text" && parentId !== undefined && !alreadyStreamed) {
      emitAssistantChildText(session, block, parentId, messageId)
    } else if (block.type === "tool_use") {
      handleAssistantTool(session, block, parentId, readFile)
    }
  }
}

const emitUnannouncedAssistantReply = (
  session: ClaudeSession,
  content: ReadonlyArray<unknown>,
  parentId: string | undefined,
  messageId: string | undefined,
  isErrorReply: boolean,
  stopReason: unknown
): void => {
  if (
    parentId === undefined &&
    messageId !== undefined &&
    messageId !== session.currentMessageId &&
    !isErrorReply
  ) {
    emitAssistantReply(session, content, messageId, stopReason)
  }
}
