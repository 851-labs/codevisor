import type { SDKMessage } from "@anthropic-ai/claude-agent-sdk"

import { maybeEmitStreamStats } from "./diff-stats.js"
import { isRecord } from "./internal.js"
import { HIDDEN_TOOLS } from "./message-tool-policy.js"
import type { ClaudeSession } from "./session.js"
import { toolKind } from "./tool-presentation.js"
import { ensureObservedTurnStarted } from "./turn-lifecycle.js"

const startStreamMessage = (
  session: ClaudeSession,
  event: Record<string, unknown>,
  parentId: string | undefined
): void => {
  const inner = event.message
  const innerId = isRecord(inner) ? String(inner.id ?? "") : undefined
  if (parentId === undefined) {
    session.currentMessageId = innerId
    session.currentMessageTextStreamed = false
    void ensureObservedTurnStarted(session)
  } else if (innerId !== undefined && innerId !== "") {
    session.subagentMessageIds.set(parentId, innerId)
  }
}

const startStreamBlock = (
  session: ClaudeSession,
  event: Record<string, unknown>,
  parentId: string | undefined
): void => {
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
    return
  }
  if (isRecord(block) && block.type === "tool_use") {
    startStreamTool(session, block, parentId)
  }
}

const retagStreamPreamble = (session: ClaudeSession, parentId: string | undefined): void => {
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
}

const startStreamTool = (
  session: ClaudeSession,
  block: Record<string, unknown>,
  parentId: string | undefined
): void => {
  retagStreamPreamble(session, parentId)
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
  announceStreamTool(session, toolUseId, toolName, parentId)
}

const announceStreamTool = (
  session: ClaudeSession,
  toolUseId: string,
  toolName: string,
  parentId: string | undefined
): void => {
  // Plan tools never open a tool call: they surface as plan updates
  // once the authoritative input arrives on the assistant message.
  if (HIDDEN_TOOLS.has(toolName)) return
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

const emitStreamText = (
  session: ClaudeSession,
  delta: Record<string, unknown>,
  parentId: string | undefined
): void => {
  // Subagent prose flows tagged with its parent tool call so clients can
  // nest it under the Task row instead of mixing it into the main thread.
  const messageId =
    parentId === undefined ? session.currentMessageId : session.subagentMessageIds.get(parentId)
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
}

const applyStreamDelta = (
  session: ClaudeSession,
  event: Record<string, unknown>,
  parentId: string | undefined,
  readFile: (path: string) => string | undefined
): void => {
  const delta = event.delta
  if (!isRecord(delta)) return
  if (delta.type === "text_delta") {
    emitStreamText(session, delta, parentId)
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
}

export const handleStreamEvent = (
  session: ClaudeSession,
  message: Extract<SDKMessage, { type: "stream_event" }>,
  readFile: (path: string) => string | undefined
): void => {
  const event = message.event as unknown as Record<string, unknown>
  const parentId = message.parent_tool_use_id ?? undefined
  switch (event.type) {
    case "message_start": {
      startStreamMessage(session, event, parentId)
      break
    }
    case "content_block_start": {
      startStreamBlock(session, event, parentId)
      break
    }
    case "content_block_delta": {
      applyStreamDelta(session, event, parentId, readFile)
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
