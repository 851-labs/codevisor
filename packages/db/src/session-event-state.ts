import type Database from "better-sqlite3"

import {
  jsonRecord,
  parseJsonRecord,
  sessionPlanFromPayload,
  type JsonRecord
} from "./event-payloads.js"
import type { SessionEventRow } from "./rows.js"

const finite = (value: unknown): number | null =>
  typeof value === "number" && Number.isFinite(value) ? value : null

const projectSessionPlan = (
  sqlite: Database.Database,
  payload: JsonRecord,
  sessionId: string
): void => {
  const sessionPlan = sessionPlanFromPayload(payload)
  // A malformed provider update must not erase the last valid checklist.
  // Empty and fully completed plans are valid snapshots and stay durable;
  // clients apply their own visibility rule.
  if (sessionPlan !== undefined) {
    sqlite
      .prepare("update sessions set session_plan = ? where id = ?")
      .run(JSON.stringify(sessionPlan), sessionId)
  }
}

const projectPendingQuestion = (
  sqlite: Database.Database,
  event: SessionEventRow,
  payload: JsonRecord,
  sessionId: string,
  update: string | undefined
): void => {
  if (
    event.kind === "session.output" &&
    update === "question" &&
    typeof payload.questionId === "string" &&
    Array.isArray(payload.questions)
  ) {
    sqlite
      .prepare("update sessions set pending_question = ? where id = ?")
      .run(event.payload, sessionId)
  } else if (
    event.kind === "session.output" &&
    update === "question_resolved" &&
    typeof payload.questionId === "string"
  ) {
    const current = sqlite
      .prepare("select pending_question from sessions where id = ?")
      .get(sessionId) as { readonly pending_question: string | null }
    const projected =
      current.pending_question === null ? undefined : parseJsonRecord(current.pending_question)
    if (projected?.questionId === payload.questionId) {
      sqlite.prepare("update sessions set pending_question = null where id = ?").run(sessionId)
    }
  } else if (
    event.kind === "session.error" ||
    (event.kind === "session.updated" &&
      (payload.turnState === "ended" || typeof payload.stopReason === "string"))
  ) {
    sqlite.prepare("update sessions set pending_question = null where id = ?").run(sessionId)
  }
}

const projectSessionUsage = (
  sqlite: Database.Database,
  payload: JsonRecord,
  sessionId: string
): void => {
  const cost = jsonRecord(payload.cost)
  const costKind = cost?.kind === "reported" || cost?.kind === "estimated" ? cost.kind : null
  sqlite
    .prepare(
      `update sessions set
           usage_used = coalesce(?, usage_used), usage_size = coalesce(?, usage_size),
           input_tokens = coalesce(?, input_tokens),
           cached_input_tokens = coalesce(?, cached_input_tokens),
           output_tokens = coalesce(?, output_tokens),
           reasoning_output_tokens = coalesce(?, reasoning_output_tokens),
           total_tokens = coalesce(?, total_tokens),
           cost_amount = coalesce(?, cost_amount),
           cost_currency = coalesce(?, cost_currency),
           cost_kind = coalesce(?, cost_kind)
         where id = ?`
    )
    .run(
      finite(payload.used),
      finite(payload.size),
      finite(payload.inputTokens),
      finite(payload.cachedInputTokens),
      finite(payload.outputTokens),
      finite(payload.reasoningOutputTokens),
      finite(payload.totalTokens),
      finite(cost?.amount),
      typeof cost?.currency === "string" ? cost.currency : null,
      costKind,
      sessionId
    )
}

export const projectSessionEventState = (
  sqlite: Database.Database,
  event: SessionEventRow,
  payload: JsonRecord,
  sessionId: string
): void => {
  // A question is session-level blocking state, not merely transcript detail.
  // Keep a single current-state projection in the same transaction as the
  // append so reconnect snapshots cannot advance past the event while losing
  // the question needed to release the provider's pending continuation.
  const update = typeof payload.sessionUpdate === "string" ? payload.sessionUpdate : undefined
  if (event.kind === "session.output" && update === "plan") {
    projectSessionPlan(sqlite, payload, sessionId)
  }
  projectPendingQuestion(sqlite, event, payload, sessionId, update)
  if (event.kind === "session.updated" && Array.isArray(payload.backgroundTasks)) {
    sqlite
      .prepare("update sessions set background_tasks = ? where id = ?")
      .run(JSON.stringify(payload.backgroundTasks), sessionId)
  }
  if (
    (event.kind === "session.updated" || event.kind === "session.output") &&
    update === "usage_update"
  ) {
    projectSessionUsage(sqlite, payload, sessionId)
  }
}
