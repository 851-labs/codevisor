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

/// Multi-agent v2 (Codex 0.161+) reports subagents as activity items on the
/// parent thread instead of `spawnAgent` calls. `started` carries the
/// `spawn_agent` call id and the new agent's thread: it becomes the visible
/// "Agent" tool call that the thread's items nest under. Its instructions are
/// encrypted, so the agent is named by its task.
///
/// `interacted` is a message sent to the agent. In the turn its chip is in,
/// that just reopens the chip; in a later turn the agent's new run gets a
/// chip of its own there (so does an agent this session never saw spawn).
/// Every chip carries the agent's thread as its task id, so opening any of
/// them shows the agent's whole history. `completed` settles the current
/// chip when the agent finishes; an interrupted agent will never produce
/// further output, so its chip is cancelled.
export const handleSubAgentActivity = (
  session: CodexSession,
  item: Record<string, unknown>,
  started: boolean,
  turnId: string | undefined
): void => {
  const agentThreadId = typeof item.agentThreadId === "string" ? item.agentThreadId : undefined
  if (agentThreadId === undefined) return
  const runId = session.collabThreads.get(agentThreadId)
  if (item.kind === "started" || item.kind === "interacted") {
    // Codex emits each activity as a started/completed pair; act on one edge.
    if (!started || typeof item.id !== "string") return
    if (
      item.kind === "interacted" &&
      runId !== undefined &&
      session.collabRunTurns.get(agentThreadId) === turnId
    ) {
      emitRunStatus(session, runId, "in_progress")
      return
    }
    session.collabThreads.set(agentThreadId, item.id)
    if (turnId === undefined) session.collabRunTurns.delete(agentThreadId)
    else session.collabRunTurns.set(agentThreadId, turnId)
    const taskName = subAgentTaskName(item.agentPath)
    const continuesAgent = item.kind === "interacted"
    void session.emit({
      kind: "session.output",
      payload: {
        _meta: {
          codevisorSubagent: {
            taskId: agentThreadId,
            ...(continuesAgent ? { continues: true } : {})
          }
        },
        kind: "agent",
        rawInput: {
          ...(taskName === undefined ? {} : { description: taskName }),
          ...(typeof item.agentPath === "string" ? { agentPath: item.agentPath } : {})
        },
        sessionUpdate: "tool_call",
        status: "in_progress",
        title: taskName === undefined ? "Agent" : `Agent: ${taskName}`,
        toolCallId: item.id
      },
      subjectId: session.key
    })
    return
  }
  const status = typeof item.kind === "string" ? subAgentActivityStatus[item.kind] : undefined
  if (started || status === undefined || runId === undefined) return
  emitRunStatus(session, runId, status)
}

const emitRunStatus = (session: CodexSession, runId: string, status: string): void => {
  void session.emit({
    kind: "session.output",
    payload: { sessionUpdate: "tool_call_update", status, toolCallId: runId },
    subjectId: session.key
  })
}

const subAgentActivityStatus: Partial<Record<string, string>> = {
  completed: "completed",
  interrupted: "cancelled"
}

/// The agent's task from its path ("/root/map_server_storage" → "Map server
/// storage").
const subAgentTaskName = (agentPath: unknown): string | undefined => {
  if (typeof agentPath !== "string") return undefined
  const task = (agentPath.split("/").at(-1) ?? "").replace(/[_-]+/g, " ").trim()
  return task.length === 0 ? undefined : task.charAt(0).toUpperCase() + task.slice(1)
}
