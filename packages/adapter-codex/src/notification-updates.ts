import { usageLimitsObserved } from "@codevisor/agent-runtime"

import { planStatus } from "./diff-presentation.js"
import { isRecord } from "./internal.js"
import type { NotificationRoute } from "./notification-route.js"
import type { CodexSession } from "./session.js"
import { codexSessionContextFrom, codexUsageLimitsFrom } from "./usage.js"

interface TokenUsageReport {
  readonly tokenUsage: Record<string, unknown>
  readonly total: Record<string, unknown>
  readonly last: Record<string, unknown>
}

interface UsageUpdate {
  readonly sessionUpdate: "usage_update"
  readonly used?: number
  readonly size?: number
  readonly inputTokens?: number
  readonly cachedInputTokens?: number
  readonly outputTokens?: number
  readonly reasoningOutputTokens?: number
  readonly totalTokens?: number
}

interface PlanEntry {
  readonly content: string
  readonly priority: "medium"
  readonly status: string
}

export const emitTokenUsageUpdate = (
  session: CodexSession,
  payload: Record<string, unknown>
): void => {
  const report = tokenUsageReport(payload)
  session.latestContext = codexSessionContextFrom(report.tokenUsage) ?? session.latestContext
  void session.emit({
    kind: "session.updated",
    payload: usageUpdate(report),
    subjectId: session.key
  })
}

export const handleRateLimitsUpdated = (
  session: CodexSession,
  payload: Record<string, unknown>
): void => {
  if (reportsAnotherLimit(payload)) return

  session.latestUsageLimits = codexUsageLimitsFrom(payload)
  void session.emit(usageLimitsObserved(session.key, session.latestUsageLimits, true))
}

export const emitAgentMessageChunk = (
  session: CodexSession,
  payload: Record<string, unknown>,
  route: NotificationRoute
): void => {
  const phase =
    typeof payload.itemId === "string" ? session.messagePhases.get(payload.itemId) : undefined
  void session.emit({
    kind: "session.output",
    payload: {
      content: { text: deltaText(payload), type: "text" },
      sessionUpdate: "agent_message_chunk",
      ...(typeof payload.itemId === "string" ? { messageId: payload.itemId } : {}),
      ...(phase === undefined ? {} : { phase }),
      ...route.parentField
    },
    subjectId: session.key
  })
}

export const emitThoughtChunk = (
  session: CodexSession,
  payload: Record<string, unknown>,
  route: NotificationRoute
): void => {
  void session.emit({
    kind: "session.output",
    payload: {
      content: { text: deltaText(payload), type: "text" },
      sessionUpdate: "agent_thought_chunk",
      ...route.parentField
    },
    subjectId: session.key
  })
}

export const emitPlanUpdate = (session: CodexSession, payload: Record<string, unknown>): void => {
  const plan = Array.isArray(payload.plan) ? payload.plan : []
  void session.emit({
    kind: "session.output",
    payload: {
      entries: plan.flatMap(planEntries),
      sessionUpdate: "plan"
    },
    subjectId: session.key
  })
}

const tokenUsageReport = (payload: Record<string, unknown>): TokenUsageReport => {
  const tokenUsage = isRecord(payload.tokenUsage) ? payload.tokenUsage : {}
  const total = isRecord(tokenUsage.total) ? tokenUsage.total : {}
  const last = isRecord(tokenUsage.last) ? tokenUsage.last : {}
  return { tokenUsage, total, last }
}

const usageUpdate = ({ tokenUsage, total, last }: TokenUsageReport): UsageUpdate => ({
  sessionUpdate: "usage_update",
  ...optionalNumericField(last, "totalTokens", "used"),
  ...optionalNumericField(tokenUsage, "modelContextWindow", "size"),
  ...optionalNumericField(total, "inputTokens", "inputTokens"),
  ...optionalNumericField(total, "cachedInputTokens", "cachedInputTokens"),
  ...optionalNumericField(total, "outputTokens", "outputTokens"),
  ...optionalNumericField(total, "reasoningOutputTokens", "reasoningOutputTokens"),
  ...optionalNumericField(total, "totalTokens", "totalTokens")
})

const optionalNumericField = (
  source: Record<string, unknown>,
  sourceKey: string,
  field: string
): Record<string, number | undefined> => {
  if (finiteNumber(source[sourceKey]) === undefined) return {}
  return { [field]: finiteNumber(source[sourceKey]) }
}

const finiteNumber = (value: unknown): number | undefined =>
  typeof value === "number" && Number.isFinite(value) ? value : undefined

const reportsAnotherLimit = (payload: Record<string, unknown>): boolean => {
  const snapshot = isRecord(payload.rateLimits) ? payload.rateLimits : {}
  return typeof snapshot.limitId === "string" && snapshot.limitId !== "codex"
}

const deltaText = (payload: Record<string, unknown>): string =>
  typeof payload.delta === "string" ? payload.delta : ""

const planEntries = (step: unknown): Array<PlanEntry> => {
  if (!isRecord(step)) return []

  return [
    {
      content: typeof step.step === "string" ? step.step : "",
      priority: "medium",
      status: planStatus(step.status)
    }
  ]
}
