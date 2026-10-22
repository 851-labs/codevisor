import type { DiffStat } from "@codevisor/api"

import { handleCollabItem, handleSubAgentActivity } from "./collab.js"
import { fileChangeStats, fileChangeTitle } from "./diff-presentation.js"
import { isRecord } from "./internal.js"
import { emitItemLifecycle } from "./items.js"
import type { NotificationRoute } from "./notification-route.js"
import type { CodexSession } from "./session.js"

export const handleItemNotification = (
  session: CodexSession,
  payload: Record<string, unknown>,
  route: NotificationRoute,
  started: boolean
): void => {
  const item = isRecord(payload.item) ? payload.item : {}
  if (item.type === "contextCompaction") {
    emitContextCompaction(session, item, route, started)
    return
  }
  if (item.type === "reasoning" && started) {
    emitThoughtStarted(session, route)
    return
  }
  if (item.type === "collabAgentToolCall") {
    handleCollabItem(session, item, started)
    return
  }
  if (item.type === "subAgentActivity") {
    handleSubAgentActivity(session, item, started, subAgentTurnId(payload))
    return
  }

  emitItemLifecycle(session, item, started, route.parentToolCallId)
}

export const emitStreamedFilePatch = (
  session: CodexSession,
  payload: Record<string, unknown>,
  route: NotificationRoute
): void => {
  const itemId = typeof payload.itemId === "string" ? payload.itemId : undefined
  if (itemId === undefined) return

  const stats = fileChangeStats(payload.changes)
  if (!session.itemKinds.has(itemId)) {
    startStreamedEdit(session, payload, itemId, stats, route)
    return
  }
  if (stats.length === 0) return

  void session.emit({
    kind: "session.output",
    payload: {
      diffStats: stats,
      sessionUpdate: "tool_call_update",
      status: "in_progress",
      toolCallId: itemId
    },
    subjectId: session.key
  })
}

const emitContextCompaction = (
  session: CodexSession,
  item: Record<string, unknown>,
  route: NotificationRoute,
  started: boolean
): void => {
  if (route.parentToolCallId !== undefined) return

  void session.emit({
    kind: "session.output",
    payload: {
      sessionUpdate: "context_compaction",
      ...(typeof item.id === "string" ? { compactionId: item.id } : {}),
      status: started ? "started" : "completed"
    },
    subjectId: session.key
  })
}

const emitThoughtStarted = (session: CodexSession, route: NotificationRoute): void => {
  void session.emit({
    kind: "session.output",
    payload: {
      content: { text: "", type: "text" },
      sessionUpdate: "agent_thought_chunk",
      ...route.parentField
    },
    subjectId: session.key
  })
}

const subAgentTurnId = (payload: Record<string, unknown>): string | undefined =>
  typeof payload.turnId === "string" ? payload.turnId : undefined

const startStreamedEdit = (
  session: CodexSession,
  payload: Record<string, unknown>,
  itemId: string,
  stats: ReadonlyArray<DiffStat>,
  route: NotificationRoute
): void => {
  session.itemKinds.set(itemId, "edit")
  void session.emit({
    kind: "session.output",
    payload: {
      kind: "edit",
      sessionUpdate: "tool_call",
      status: "in_progress",
      title: fileChangeTitle(payload.changes, false),
      toolCallId: itemId,
      ...(stats.length === 0 ? {} : { diffStats: stats }),
      ...route.parentField
    },
    subjectId: session.key
  })
}
