import { firstLine } from "./internal.js"
import type { CodexSession } from "./session.js"

/// Collab tool calls are how a codex agent drives its subagents: `spawnAgent`
/// becomes the visible "Agent" tool call that child-thread items nest under;
/// `closeAgent` settles it. `wait`/`sendInput`/`resumeAgent` are plumbing and
/// stay invisible.
export const handleCollabItem = (
  session: CodexSession,
  item: Record<string, unknown>,
  started: boolean
): void => {
  const itemId = typeof item.id === "string" ? item.id : undefined
  if (itemId === undefined) return
  const tool = typeof item.tool === "string" ? item.tool : ""
  const receivers = Array.isArray(item.receiverThreadIds)
    ? item.receiverThreadIds.filter((value): value is string => typeof value === "string")
    : []
  if (tool === "spawnAgent") {
    // Register on both lifecycle edges: the child's items must be attributable
    // from the very first notification.
    for (const receiver of receivers) {
      session.collabThreads.set(receiver, itemId)
    }
    if (started) {
      void session.emit({
        kind: "session.output",
        payload: {
          kind: "agent",
          sessionUpdate: "tool_call",
          status: "in_progress",
          title: collabAgentTitle(item),
          toolCallId: itemId,
          ...(typeof item.prompt === "string" ? { rawInput: { prompt: item.prompt } } : {})
        },
        subjectId: session.key
      })
    } else if (item.status === "failed") {
      void session.emit({
        kind: "session.output",
        payload: { sessionUpdate: "tool_call_update", status: "failed", toolCallId: itemId },
        subjectId: session.key
      })
    }
    // A successful spawn completion means the child is now RUNNING — the
    // Agent call stays open until closeAgent (or turn end settles it).
    return
  }
  if (tool === "closeAgent" && !started && item.status !== "failed") {
    for (const receiver of receivers) {
      const spawnId = session.collabThreads.get(receiver)
      if (spawnId === undefined) continue
      void session.emit({
        kind: "session.output",
        payload: { sessionUpdate: "tool_call_update", status: "completed", toolCallId: spawnId },
        subjectId: session.key
      })
    }
  }
  // wait / sendInput / resumeAgent: no visible rows.
}

const collabAgentTitle = (item: Record<string, unknown>): string => {
  if (typeof item.prompt === "string" && item.prompt.trim().length > 0) {
    return `Agent: ${promptSnippet(item.prompt)}`
  }
  return typeof item.model === "string" && item.model.length > 0 ? `Agent (${item.model})` : "Agent"
}

/// Codex spawn prompts are full instruction blobs, so the title takes a short
/// snippet, cut at a word boundary — a hard slice ends mid-phrase and reads
/// like part of the label ("… Read-only").
const promptSnippet = (prompt: string): string => {
  const line = firstLine(prompt.trim())
  if (line.length <= 48) return line
  const cut = line.slice(0, 48)
  const boundary = cut.lastIndexOf(" ")
  return `${(boundary > 20 ? cut.slice(0, boundary) : cut).trimEnd()}…`
}

/// An interrupted subagent will never produce further output; settle its
/// spawn call as cancelled so nested rows don't spin forever.
export const handleSubAgentActivity = (
  session: CodexSession,
  item: Record<string, unknown>
): void => {
  if (item.kind !== "interrupted") return
  const agentThreadId = typeof item.agentThreadId === "string" ? item.agentThreadId : undefined
  if (agentThreadId === undefined) return
  const spawnId = session.collabThreads.get(agentThreadId)
  if (spawnId === undefined) return
  void session.emit({
    kind: "session.output",
    payload: { sessionUpdate: "tool_call_update", status: "cancelled", toolCallId: spawnId },
    subjectId: session.key
  })
}
