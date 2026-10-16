import { firstLine } from "./internal.js"
import type { CodexSession } from "./session.js"

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
      emitRunStatus(session, itemId, "failed")
    }
    return
  }
  if (tool === "closeAgent" && !started && item.status !== "failed") {
    for (const receiver of receivers) {
      const spawnId = session.collabThreads.get(receiver)
      if (spawnId === undefined) continue
      emitRunStatus(session, spawnId, "completed")
    }
  }
}

const collabAgentTitle = (item: Record<string, unknown>): string => {
  if (typeof item.prompt === "string" && item.prompt.trim().length > 0) {
    return `Agent: ${promptSnippet(item.prompt)}`
  }
  return typeof item.model === "string" && item.model.length > 0 ? `Agent (${item.model})` : "Agent"
}

const promptSnippet = (prompt: string): string => {
  const line = firstLine(prompt.trim())
  if (line.length <= 48) return line
  const cut = line.slice(0, 48)
  const boundary = cut.lastIndexOf(" ")
  return `${(boundary > 20 ? cut.slice(0, boundary) : cut).trimEnd()}…`
}

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

const subAgentTaskName = (agentPath: unknown): string | undefined => {
  if (typeof agentPath !== "string") return undefined
  const task = (agentPath.split("/").at(-1) ?? "").replace(/[_-]+/g, " ").trim()
  return task.length === 0 ? undefined : task.charAt(0).toUpperCase() + task.slice(1)
}
