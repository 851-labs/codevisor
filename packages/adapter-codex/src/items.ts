import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { openCommandTerminal, settleCommandTerminal } from "./command-terminals.js"
import {
  commandStatus,
  fileChangeDiffBlocks,
  fileChangeStats,
  fileChangeTitle,
  patchStatus
} from "./diff-presentation.js"
import { firstLine } from "./internal.js"
import type { CodexSession } from "./session.js"

/// Maps codex's `MessagePhase` ("commentary" | "final_answer") to the wire's
/// phase vocabulary. Absent/unknown stays undefined — per codex convention
/// untagged messages keep legacy semantics, which on our wire means "let the
/// client render optimistically" rather than asserting finality.
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
    case "commandExecution": {
      const command = typeof item.command === "string" ? item.command : ""
      if (started) {
        session.itemKinds.set(itemId, "execute")
        if (command.length > 0) session.itemTitles.set(itemId, command)
        openCommandTerminal(session, itemId, command, item.source)
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
        settleCommandTerminal(session, itemId, item)
        void session.emit(
          event({
            sessionUpdate: "tool_call_update",
            status: commandStatus(item),
            toolCallId: itemId,
            ...(command.length > 0 ? { rawInput: { command } } : {}),
            ...(typeof item.aggregatedOutput === "string"
              ? { rawOutput: item.aggregatedOutput }
              : {}),
            ...(typeof item.exitCode === "number" ? { exitCode: item.exitCode } : {})
          })
        )
      }
      break
    }
    case "fileChange": {
      const stats = fileChangeStats(item.changes)
      const content = fileChangeDiffBlocks(item.changes)
      if (started) {
        // The streamed patchUpdated events may have opened this call already;
        // tool_call upserts merge in the client, so re-sending is safe and
        // carries the final title/diff content.
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
      break
    }
    case "plan": {
      // EXPERIMENTAL codex plan-mode proposed-plan document. Codevisor doesn't
      // expose the collaboration-mode toggle yet, but if a plan item arrives
      // it renders as a plan document rather than an opaque tool call. The
      // completed item is authoritative; deltas are ignored.
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
      const title = `${String(item.server ?? "")}.${String(item.tool ?? "")}`
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
      break
    }
    case "webSearch": {
      // The started item often lacks the query — codex fills it in as the
      // model generates the call — so the completed item re-titles the call
      // with the authoritative query.
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
            // Not ACP vocabulary — Codevisor's own extension so clients can
            // phrase web searches as searches instead of fetches.
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
      // Text already streamed via item/agentMessage/delta; the lifecycle only
      // carries the message's phase (harmony commentary vs final answer).
      const phase = wirePhase(item.phase)
      if (started) {
        if (phase !== undefined) session.messagePhases.set(itemId, phase)
        break
      }
      // Completion can reveal a phase the started item lacked (backends that
      // tag only the finished item). A zero-length chunk retro-tags the span
      // clients already streamed; skip when the deltas were tagged all along.
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
      break
    }
    default:
      break
  }
}
