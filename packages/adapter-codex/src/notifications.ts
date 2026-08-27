import { randomUUID } from "node:crypto"
import { handleCollabItem, handleSubAgentActivity } from "./collab.js"
import { fileChangeStats, fileChangeTitle, planStatus } from "./diff-presentation.js"
import { codexErrorDetails, codexRetryStatus } from "./errors.js"
import { emitGoalCleared, flushPendingGoalSnapshot, handleGoalUpdated } from "./goals.js"
import { isRecord } from "./internal.js"
import { emitItemLifecycle } from "./items.js"
import { cancelPendingQuestions } from "./questions.js"
import type { CodexSession } from "./session.js"

// MARK: notification mapping

export const codexThreadTitle = (thread: Record<string, unknown>): string | undefined => {
  for (const value of [thread.name, thread.preview]) {
    if (typeof value !== "string") continue
    const title = value.trim()
    if (title.length > 0) return title
  }
  return undefined
}

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
    await emitCodexSessionTitle(
      session,
      thread === undefined ? undefined : codexThreadTitle(thread)
    )
  } catch {
    // Older app-servers may not expose thread names. The first-prompt title
    // stored by Codevisor remains the fallback in that case.
  }
}

export const handleNotification = (
  session: CodexSession,
  method: string,
  params: unknown
): void => {
  const payload = isRecord(params) ? params : {}
  // Every notification is thread-scoped. Collab subagents run as separate
  // threads on the same connection: their items nest under the spawnAgent
  // tool call, their turn lifecycle must NOT drive the session's turn state,
  // and traffic from a thread we can't attribute is dropped rather than mixed
  // into the main transcript.
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
    case "thread/tokenUsage/updated": {
      const tokenUsage = isRecord(payload.tokenUsage) ? payload.tokenUsage : {}
      const total = isRecord(tokenUsage.total) ? tokenUsage.total : {}
      const last = isRecord(tokenUsage.last) ? tokenUsage.last : {}
      const number = (value: unknown): number | undefined =>
        typeof value === "number" && Number.isFinite(value) ? value : undefined
      void session.emit({
        kind: "session.updated",
        payload: {
          sessionUpdate: "usage_update",
          ...(number(last.totalTokens) === undefined ? {} : { used: number(last.totalTokens) }),
          ...(number(tokenUsage.modelContextWindow) === undefined
            ? {}
            : { size: number(tokenUsage.modelContextWindow) }),
          ...(number(total.inputTokens) === undefined
            ? {}
            : { inputTokens: number(total.inputTokens) }),
          ...(number(total.cachedInputTokens) === undefined
            ? {}
            : { cachedInputTokens: number(total.cachedInputTokens) }),
          ...(number(total.outputTokens) === undefined
            ? {}
            : { outputTokens: number(total.outputTokens) }),
          ...(number(total.reasoningOutputTokens) === undefined
            ? {}
            : { reasoningOutputTokens: number(total.reasoningOutputTokens) }),
          ...(number(total.totalTokens) === undefined
            ? {}
            : { totalTokens: number(total.totalTokens) })
        },
        subjectId: session.key
      })
      break
    }
    case "thread/name/updated": {
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
      const turn = isRecord(payload.turn) ? payload.turn : {}
      const status = typeof turn.status === "string" ? turn.status : "completed"
      const stopReason =
        status === "interrupted" || session.interruptRequested
          ? "cancelled"
          : status === "failed"
            ? "end_turn"
            : "end_turn"
      const completedError =
        status === "failed" && !session.interruptRequested && isRecord(turn.error)
          ? codexErrorDetails({ error: turn.error })
          : undefined
      const terminalError = completedError ?? session.pendingTurnError
      const pending = session.pendingPrompt
      session.pendingPrompt = undefined
      session.interruptRequested = false
      const turnId = session.activeTurnId ?? randomUUID()
      session.activeTurnId = undefined
      session.pendingTurnError = undefined
      // A turn that ends with questions still open (interrupt, failure)
      // invalidates them — clients must not keep showing the picker.
      cancelPendingQuestions(session)
      // Rate-limited goal accounting flushes before the turn closes so the
      // final totals are persisted ahead of the ended event.
      void refreshCodexSessionTitle(session)
        .then(() => flushPendingGoalSnapshot(session))
        .then(() =>
          session.emit({
            kind: "session.updated",
            payload: {
              initiatedBy: pending === undefined ? "agent" : "user",
              stopReason,
              ...(terminalError === undefined ? {} : { stopDetail: terminalError.message }),
              ...(terminalError?.stopKind === undefined
                ? {}
                : { stopKind: terminalError.stopKind }),
              ...(terminalError?.retryable === true ? { retryable: true } : {}),
              turnId,
              turnState: "ended"
            },
            subjectId: session.key
          })
        )
        .then(() => pending?.resolve({ stopReason }))
      break
    }
    case "item/agentMessage/delta": {
      // Finality captured from the item's `item/started` (see wirePhase): lets
      // clients style the final answer correctly from the very first chunk.
      const phase =
        typeof payload.itemId === "string" ? session.messagePhases.get(payload.itemId) : undefined
      void session.emit({
        kind: "session.output",
        payload: {
          content: { text: String(payload.delta ?? ""), type: "text" },
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
          content: { text: String(payload.delta ?? ""), type: "text" },
          sessionUpdate: "agent_thought_chunk",
          ...parentField
        },
        subjectId: session.key
      })
      break
    }
    case "item/started":
    case "item/completed": {
      const item = isRecord(payload.item) ? payload.item : {}
      if (item.type === "contextCompaction") {
        // A collab subagent's context belongs to its nested thread, not the
        // main chat's status line. Main-thread compaction is a canonical v2
        // item with matching started/completed ids.
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
        break
      }
      // Codex (as of 0.142) emits no reasoning text deltas — the reasoning
      // item's lifecycle is the only thinking signal, so an empty thought
      // chunk drives the client's ephemeral "Thinking…" state through the
      // otherwise silent gap.
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
        break
      }
      if (item.type === "collabAgentToolCall") {
        handleCollabItem(session, item, method === "item/started")
        break
      }
      if (item.type === "subAgentActivity") {
        handleSubAgentActivity(session, item)
        break
      }
      emitItemLifecycle(session, item, method === "item/started", parentToolCallId)
      break
    }
    case "item/commandExecution/outputDelta": {
      const itemId = typeof payload.itemId === "string" ? payload.itemId : undefined
      const delta = typeof payload.delta === "string" ? payload.delta : undefined
      if (itemId === undefined || delta === undefined) break
      session.commandTerminals.get(itemId)?.stream.output(delta)
      break
    }
    case "item/fileChange/patchUpdated": {
      // Codex streams the patch as the model generates it (gated behind the
      // apply_patch_streaming_events feature we enable at spawn) — this is
      // the realtime counter signal. These arrive BEFORE item/started for
      // the same item, so the first one opens the tool call.
      const itemId = typeof payload.itemId === "string" ? payload.itemId : undefined
      if (itemId === undefined) break
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
        break
      }
      if (stats.length === 0) break
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
                    content: String(step.step ?? ""),
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
      if (payload.willRetry === true) {
        void session.emit({
          kind: "session.updated",
          payload: {
            retrying: codexRetryStatus(payload),
            ...(session.activeTurnId === undefined ? {} : { turnId: session.activeTurnId })
          },
          subjectId: session.key
        })
        break
      }
      const terminalError = codexErrorDetails(payload)
      if (session.activeTurnId !== undefined) {
        session.pendingTurnError = terminalError
        break
      }
      void session.emit({
        kind: "session.error",
        payload: { message: terminalError.message },
        subjectId: session.key
      })
      break
    }
    default:
      // turn/diff/updated is deliberately ignored for stats: it aggregates the
      // whole turn, and Codevisor counters are per tool call.
      break
  }
}
