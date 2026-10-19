import { randomUUID } from "node:crypto"

import { usageLimitsObserved } from "@codevisor/agent-runtime"

import { handleCollabItem, handleSubAgentActivity } from "./collab.js"
import { fileChangeStats, fileChangeTitle, planStatus } from "./diff-presentation.js"
import { codexErrorDetails, codexRetryStatus, codexSignedOutDetail } from "./errors.js"
import { emitGoalCleared, flushPendingGoalSnapshot, handleGoalUpdated } from "./goals.js"
import { isRecord } from "./internal.js"
import { emitItemLifecycle } from "./items.js"
import { cancelPendingQuestions } from "./questions.js"
import type { CodexSession } from "./session.js"
import { refreshCodexSkills } from "./skills.js"
import { codexSessionContextFrom, codexUsageLimitsFrom } from "./usage.js"

export const codexThreadTitle = (thread: Record<string, unknown>): string | undefined => {
  for (const value of [thread.name, thread.preview]) {
    if (typeof value !== "string") continue
    const title = value.trim()
    if (title.length > 0) return title
  }
  return undefined
}

const finiteNumber = (value: unknown): number | undefined =>
  typeof value === "number" && Number.isFinite(value) ? value : undefined

const emitCodexSessionTitle = async (
  session: CodexSession,
  title: string | undefined
): Promise<void> => {
  if (title === undefined || title === session.lastHarnessTitle) return
  session.lastHarnessTitle = title
  await session.emit({
    kind: "session.updated",
    payload: { sessionUpdate: "session_info_update", title },
    subjectId: session.key
  })
}

const refreshCodexSessionTitle = async (session: CodexSession): Promise<void> => {
  try {
    const response: unknown = await session.client.request("thread/read", {
      includeTurns: false,
      threadId: session.threadId
    })
    const thread = isRecord(response) && isRecord(response.thread) ? response.thread : undefined
    session.titleGenerator?.observeName(thread?.name)
    await emitCodexSessionTitle(
      session,
      typeof thread?.name === "string" && thread.name.trim().length > 0
        ? thread.name.trim()
        : undefined
    )
  } catch {}
}

const optionalNumericField = (
  source: Record<string, unknown>,
  sourceKey: string,
  field: string
): Record<string, number | undefined> => {
  if (finiteNumber(source[sourceKey]) === undefined) return {}
  return { [field]: finiteNumber(source[sourceKey]) }
}

const emitTokenUsageUpdate = (session: CodexSession, payload: Record<string, unknown>): void => {
  const tokenUsage = isRecord(payload.tokenUsage) ? payload.tokenUsage : {}
  const total = isRecord(tokenUsage.total) ? tokenUsage.total : {}
  const last = isRecord(tokenUsage.last) ? tokenUsage.last : {}
  session.latestContext = codexSessionContextFrom(tokenUsage) ?? session.latestContext
  void session.emit({
    kind: "session.updated",
    payload: {
      sessionUpdate: "usage_update",
      ...optionalNumericField(last, "totalTokens", "used"),
      ...optionalNumericField(tokenUsage, "modelContextWindow", "size"),
      ...optionalNumericField(total, "inputTokens", "inputTokens"),
      ...optionalNumericField(total, "cachedInputTokens", "cachedInputTokens"),
      ...optionalNumericField(total, "outputTokens", "outputTokens"),
      ...optionalNumericField(total, "reasoningOutputTokens", "reasoningOutputTokens"),
      ...optionalNumericField(total, "totalTokens", "totalTokens")
    },
    subjectId: session.key
  })
}

const completeNotificationTurn = (
  session: CodexSession,
  payload: Record<string, unknown>
): void => {
  const turn = isRecord(payload.turn) ? payload.turn : {}
  const status = typeof turn.status === "string" ? turn.status : "completed"
  const signedOut =
    !session.interruptRequested && session.pendingTurnError?.stopKind === "authRequired"
  const stopReason =
    !signedOut && (status === "interrupted" || session.interruptRequested)
      ? "cancelled"
      : "end_turn"
  const completedError =
    status === "failed" && !session.interruptRequested && isRecord(turn.error)
      ? codexErrorDetails({ error: turn.error })
      : undefined
  const reportedError = signedOut
    ? session.pendingTurnError
    : (completedError ?? session.pendingTurnError)
  if (reportedError !== undefined && rejectsReasoningSummaries(reportedError.message)) {
    session.reasoningSummariesRejected = true
  }
  const sharedAuthRejected = session.client.authRejected?.() === true
  const pending = session.pendingPrompt
  session.pendingPrompt = undefined
  session.interruptRequested = false
  const turnId = session.activeTurnId ?? randomUUID()
  session.activeTurnId = undefined
  session.pendingTurnError = undefined
  cancelPendingQuestions(session)
  void refreshCodexSessionTitle(session)
    .then(() => flushPendingGoalSnapshot(session))
    .then(() => confirmSignedOut(session, status, reportedError, sharedAuthRejected))
    .then(async (terminalError) => {
      await session.emit({
        kind: "session.updated",
        payload: {
          initiatedBy: pending === undefined ? "agent" : "user",
          stopReason,
          ...(terminalError === undefined ? {} : { stopDetail: terminalError.message }),
          ...(terminalError?.stopKind === undefined ? {} : { stopKind: terminalError.stopKind }),
          ...(terminalError?.retryable === true ? { retryable: true } : {}),
          turnId,
          turnState: "ended"
        },
        subjectId: session.key
      })
      return terminalError
    })
    .then((terminalError) => {
      pending?.resolve({ stopReason })
      if (pending !== undefined && status === "completed" && terminalError === undefined) {
        void session.titleGenerator?.onTurnCompleted()
      }
    })
}

const signedOutError = {
  message: codexSignedOutDetail,
  retryable: false,
  stopKind: "authRequired" as const
}

const confirmSignedOut = async (
  session: CodexSession,
  status: string,
  error: CodexSession["pendingTurnError"],
  sharedAuthRejected: boolean
): Promise<CodexSession["pendingTurnError"]> => {
  if (status !== "failed" || error === undefined || error.stopKind !== undefined) return error
  if (sharedAuthRejected) return signedOutError
  try {
    const result = await session.client.request<unknown>("account/read", { refreshToken: false })
    return isRecord(result) && result.account === null && result.requiresOpenaiAuth === true
      ? signedOutError
      : error
  } catch {
    return error
  }
}

const rejectsReasoningSummaries = (message: string): boolean =>
  /reasoning summar/i.test(message) && /verif/i.test(message)

const handleNotificationItemLifecycle = (
  session: CodexSession,
  method: string,
  payload: Record<string, unknown>,
  parentToolCallId: string | undefined,
  parentField: { parentToolCallId?: string }
): void => {
  const item = isRecord(payload.item) ? payload.item : {}
  if (item.type === "contextCompaction") {
    if (parentToolCallId === undefined) {
      void session.emit({
        kind: "session.output",
        payload: {
          sessionUpdate: "context_compaction",
          ...(typeof item.id === "string" ? { compactionId: item.id } : {}),
          status: method === "item/started" ? "started" : "completed"
        },
        subjectId: session.key
      })
    }
    return
  }
  if (item.type === "reasoning" && method === "item/started") {
    void session.emit({
      kind: "session.output",
      payload: {
        content: { text: "", type: "text" },
        sessionUpdate: "agent_thought_chunk",
        ...parentField
      },
      subjectId: session.key
    })
    return
  }
  if (item.type === "collabAgentToolCall") {
    handleCollabItem(session, item, method === "item/started")
    return
  }
  if (item.type === "subAgentActivity") {
    const turnId = typeof payload.turnId === "string" ? payload.turnId : undefined
    handleSubAgentActivity(session, item, method === "item/started", turnId)
    return
  }
  emitItemLifecycle(session, item, method === "item/started", parentToolCallId)
}

const emitStreamedFilePatch = (
  session: CodexSession,
  payload: Record<string, unknown>,
  parentField: { parentToolCallId?: string }
): void => {
  const itemId = typeof payload.itemId === "string" ? payload.itemId : undefined
  if (itemId === undefined) return
  const stats = fileChangeStats(payload.changes)
  if (!session.itemKinds.has(itemId)) {
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
        ...parentField
      },
      subjectId: session.key
    })
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

const handleNotificationError = (session: CodexSession, payload: Record<string, unknown>): void => {
  const terminalError = codexErrorDetails(payload)
  if (terminalError.stopKind === "authRequired" && session.activeTurnId !== undefined) {
    if (session.pendingTurnError?.stopKind !== "authRequired") {
      session.pendingTurnError = terminalError
      void session.client
        .request("turn/interrupt", { threadId: session.threadId, turnId: session.activeTurnId })
        .catch(() => undefined)
    }
    return
  }
  if (payload.willRetry === true) {
    void session.emit({
      kind: "session.updated",
      payload: {
        retrying: codexRetryStatus(payload),
        ...(session.activeTurnId === undefined ? {} : { turnId: session.activeTurnId })
      },
      subjectId: session.key
    })
    return
  }
  if (session.activeTurnId !== undefined) {
    session.pendingTurnError = terminalError
    return
  }
  void session.emit({
    kind: "session.error",
    payload: { message: terminalError.message },
    subjectId: session.key
  })
}

export const handleNotification = (
  session: CodexSession,
  method: string,
  params: unknown
): void => {
  if (session.titleGenerator?.handleNotification(method, params)) return
  const payload = isRecord(params) ? params : {}
  const threadId = typeof payload.threadId === "string" ? payload.threadId : undefined
  const isForeign = threadId !== undefined && threadId !== session.threadId
  const parentToolCallId = isForeign ? session.collabThreads.get(threadId) : undefined
  if (isForeign) {
    const routable =
      method === "item/started" ||
      method === "item/completed" ||
      method === "item/agentMessage/delta" ||
      method === "item/reasoning/textDelta" ||
      method === "item/reasoning/summaryTextDelta" ||
      method === "item/fileChange/patchUpdated" ||
      method === "item/commandExecution/outputDelta"
    if (!routable || parentToolCallId === undefined) return
  }
  const parentField = parentToolCallId === undefined ? {} : { parentToolCallId }
  switch (method) {
    case "skills/changed": {
      void refreshCodexSkills(session, true)
      break
    }
    case "thread/tokenUsage/updated": {
      emitTokenUsageUpdate(session, payload)
      break
    }
    case "account/rateLimits/updated": {
      const snapshot = isRecord(payload.rateLimits) ? payload.rateLimits : {}
      if (typeof snapshot.limitId === "string" && snapshot.limitId !== "codex") break
      void session.emit(usageLimitsObserved(session.key, codexUsageLimitsFrom(payload), true))
      break
    }
    case "thread/name/updated": {
      session.titleGenerator?.observeName(payload.threadName)
      const title = typeof payload.threadName === "string" ? payload.threadName.trim() : undefined
      if (title === undefined || title.length === 0) {
        void refreshCodexSessionTitle(session)
      } else {
        void emitCodexSessionTitle(session, title)
      }
      break
    }
    case "turn/started": {
      const turn = isRecord(payload.turn) ? payload.turn : {}
      session.activeTurnId = typeof turn.id === "string" ? turn.id : randomUUID()
      session.pendingTurnError = undefined
      void session.emit({
        kind: "session.updated",
        payload: {
          initiatedBy: session.pendingPrompt === undefined ? "agent" : "user",
          turnId: session.activeTurnId,
          turnState: "started"
        },
        subjectId: session.key
      })
      break
    }
    case "turn/completed": {
      completeNotificationTurn(session, payload)
      break
    }
    case "item/agentMessage/delta": {
      const phase =
        typeof payload.itemId === "string" ? session.messagePhases.get(payload.itemId) : undefined
      void session.emit({
        kind: "session.output",
        payload: {
          content: { text: typeof payload.delta === "string" ? payload.delta : "", type: "text" },
          sessionUpdate: "agent_message_chunk",
          ...(typeof payload.itemId === "string" ? { messageId: payload.itemId } : {}),
          ...(phase === undefined ? {} : { phase }),
          ...parentField
        },
        subjectId: session.key
      })
      break
    }
    case "item/reasoning/textDelta":
    case "item/reasoning/summaryTextDelta": {
      void session.emit({
        kind: "session.output",
        payload: {
          content: { text: typeof payload.delta === "string" ? payload.delta : "", type: "text" },
          sessionUpdate: "agent_thought_chunk",
          ...parentField
        },
        subjectId: session.key
      })
      break
    }
    case "item/started":
    case "item/completed": {
      handleNotificationItemLifecycle(session, method, payload, parentToolCallId, parentField)
      break
    }
    case "item/fileChange/patchUpdated": {
      emitStreamedFilePatch(session, payload, parentField)
      break
    }
    case "thread/goal/updated": {
      handleGoalUpdated(session, payload)
      break
    }
    case "thread/goal/cleared": {
      void emitGoalCleared(session)
      break
    }
    case "turn/plan/updated": {
      const plan = Array.isArray(payload.plan) ? payload.plan : []
      void session.emit({
        kind: "session.output",
        payload: {
          entries: plan.flatMap((step) =>
            isRecord(step)
              ? [
                  {
                    content: typeof step.step === "string" ? step.step : "",
                    priority: "medium",
                    status: planStatus(step.status)
                  }
                ]
              : []
          ),
          sessionUpdate: "plan"
        },
        subjectId: session.key
      })
      break
    }
    case "error": {
      handleNotificationError(session, payload)
      break
    }
    default:
      break
  }
}
