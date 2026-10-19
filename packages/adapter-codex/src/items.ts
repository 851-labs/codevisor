import type { RuntimeEvent } from "@codevisor/agent-runtime"

import {
  commandStatus,
  fileChangeDiffBlocks,
  fileChangeStats,
  fileChangeTitle,
  patchStatus
} from "./diff-presentation.js"
import { firstLine } from "./internal.js"
import { askAsyncQuestions } from "./questions.js"
import type { CodexSession } from "./session.js"

export const wirePhase = (raw: unknown): "commentary" | "final" | undefined =>
  raw === "commentary" ? "commentary" : raw === "final_answer" ? "final" : undefined

export const emitItemLifecycle = (
  session: CodexSession,
  item: Record<string, unknown>,
  started: boolean,
  parentToolCallId?: string
): void => {
  const itemId = typeof item.id === "string" ? item.id : undefined
  if (itemId === undefined) return
  const type = typeof item.type === "string" ? item.type : ""
  const parentField = parentToolCallId === undefined ? {} : { parentToolCallId }
  const event = (payload: Record<string, unknown>): RuntimeEvent => ({
    kind: "session.output",
    payload: { ...payload, ...parentField },
    subjectId: session.key
  })

  switch (type) {
    case "imageGeneration": {
      emitImageItem(session, item, itemId, started, event)
      break
    }
    case "commandExecution": {
      emitCommandItem(session, item, itemId, started, event)
      break
    }
    case "fileChange": {
      emitFileChangeItem(session, item, itemId, started, event)
      break
    }
    case "plan": {
      if (!started && typeof item.text === "string" && item.text.length > 0) {
        void session.emit(
          event({
            markdown: item.text,
            sessionUpdate: "plan_document"
          })
        )
      }
      break
    }
    case "mcpToolCall": {
      emitMcpItem(session, item, itemId, started, event)
      break
    }
    case "webSearch": {
      const query = typeof item.query === "string" && item.query.length > 0 ? item.query : undefined
      const title =
        query !== undefined
          ? `Searched for ${query}`
          : started
            ? "Searching the web"
            : "Searched the web"
      if (started) {
        void session.emit(
          event({
            kind: "web_search",
            sessionUpdate: "tool_call",
            status: "in_progress",
            title,
            toolCallId: itemId
          })
        )
      } else {
        void session.emit(
          event({
            sessionUpdate: "tool_call_update",
            status: "completed",
            title,
            toolCallId: itemId
          })
        )
      }
      break
    }
    case "agentMessage": {
      if (!started && item.delivery === "async") emitAsyncMessage(session, item, itemId, event)
      applyMessagePhase(session, item, itemId, started, event)
      break
    }
    default:
      break
  }
}

type ItemEvent = (payload: Record<string, unknown>) => RuntimeEvent

function emitImageItem(
  session: CodexSession,
  item: Record<string, unknown>,
  itemId: string,
  started: boolean,
  event: ItemEvent
): void {
  const failed = item.status === "failed"
  void session.emit(
    event({
      sessionUpdate: started ? "tool_call" : "tool_call_update",
      kind: "image_generation",
      toolCallId: itemId,
      status: started ? "in_progress" : failed ? "failed" : "completed",
      title: started ? "Generating image" : failed ? "Image generation failed" : "Generated image",
      ...(!started && !failed
        ? {
            generatedImage: {
              ...(typeof item.result === "string" ? { result: item.result } : {}),
              ...(typeof item.savedPath === "string" ? { savedPath: item.savedPath } : {})
            }
          }
        : {}),
      ...(failed
        ? {
            rawOutput: {
              message: "Image generation failed. Try again.",
              ...(item.failure == null ? {} : { failure: item.failure })
            }
          }
        : {})
    })
  )
}

function emitCommandItem(
  session: CodexSession,
  item: Record<string, unknown>,
  itemId: string,
  started: boolean,
  event: ItemEvent
): void {
  const command = typeof item.command === "string" ? item.command : ""
  if (started) {
    session.itemKinds.set(itemId, "execute")
    if (command.length > 0) session.itemTitles.set(itemId, command)
    void session.emit(
      event({
        kind: "execute",
        sessionUpdate: "tool_call",
        status: "in_progress",
        title: command.length > 0 ? `Ran ${firstLine(command)}` : "Ran command",
        toolCallId: itemId,
        ...(command.length > 0 ? { rawInput: { command } } : {})
      })
    )
  } else {
    void session.emit(
      event({
        sessionUpdate: "tool_call_update",
        status: commandStatus(item),
        toolCallId: itemId,
        ...(command.length > 0 ? { rawInput: { command } } : {}),
        ...(typeof item.aggregatedOutput === "string" ? { rawOutput: item.aggregatedOutput } : {}),
        ...(typeof item.exitCode === "number" ? { exitCode: item.exitCode } : {})
      })
    )
  }
}

function emitFileChangeItem(
  session: CodexSession,
  item: Record<string, unknown>,
  itemId: string,
  started: boolean,
  event: ItemEvent
): void {
  const stats = fileChangeStats(item.changes)
  const content = fileChangeDiffBlocks(item.changes)
  if (started) {
    session.itemKinds.set(itemId, "edit")
    session.itemTitles.set(itemId, fileChangeTitle(item.changes, false))
    void session.emit(
      event({
        kind: "edit",
        sessionUpdate: "tool_call",
        status: "in_progress",
        title: fileChangeTitle(item.changes, false),
        toolCallId: itemId,
        ...(stats.length === 0 ? {} : { diffStats: stats }),
        ...(content.length === 0 ? {} : { content })
      })
    )
  } else {
    void session.emit(
      event({
        sessionUpdate: "tool_call_update",
        status: patchStatus(item),
        title: fileChangeTitle(item.changes, true),
        toolCallId: itemId,
        ...(stats.length === 0 ? {} : { diffStats: stats }),
        ...(content.length === 0 ? {} : { content })
      })
    )
  }
}

function emitMcpItem(
  session: CodexSession,
  item: Record<string, unknown>,
  itemId: string,
  started: boolean,
  event: ItemEvent
): void {
  const server = typeof item.server === "string" ? item.server : ""
  const tool = typeof item.tool === "string" ? item.tool : ""
  const title = `${server}.${tool}`
  if (started) {
    session.itemKinds.set(itemId, "other")
    void session.emit(
      event({
        kind: "other",
        sessionUpdate: "tool_call",
        status: "in_progress",
        title,
        toolCallId: itemId,
        ...(item.arguments === undefined ? {} : { rawInput: item.arguments })
      })
    )
  } else {
    void session.emit(
      event({
        sessionUpdate: "tool_call_update",
        status: item.status === "failed" ? "failed" : "completed",
        toolCallId: itemId,
        ...(item.result !== undefined && item.result !== null
          ? { rawOutput: item.result }
          : item.error !== undefined && item.error !== null
            ? { rawOutput: item.error }
            : {})
      })
    )
  }
}

function emitAsyncMessage(
  session: CodexSession,
  item: Record<string, unknown>,
  itemId: string,
  event: ItemEvent
): void {
  if (Array.isArray(item.questions) && item.questions.length > 0) {
    askAsyncQuestions(session, itemId, item.questions)
    return
  }
  if (typeof item.text !== "string" || item.text.length === 0) return
  const phase = wirePhase(item.phase)
  void session.emit(
    event({
      content: { text: item.text, type: "text" },
      messageId: itemId,
      sessionUpdate: "agent_message_chunk",
      ...(phase === undefined ? {} : { phase })
    })
  )
}

function applyMessagePhase(
  session: CodexSession,
  item: Record<string, unknown>,
  itemId: string,
  started: boolean,
  event: ItemEvent
): void {
  const phase = wirePhase(item.phase)
  if (started) {
    if (phase !== undefined) session.messagePhases.set(itemId, phase)
    return
  }
  if (phase !== undefined && session.messagePhases.get(itemId) !== phase) {
    void session.emit(
      event({
        content: { text: "", type: "text" },
        messageId: itemId,
        phase,
        sessionUpdate: "agent_message_chunk"
      })
    )
  }
  session.messagePhases.delete(itemId)
}
