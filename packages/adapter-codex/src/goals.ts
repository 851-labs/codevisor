import type { GoalStatus, SessionGoal } from "@codevisor/api"

import { isRecord } from "./internal.js"
import type { CodexSession } from "./session.js"

export const GOAL_ACCOUNTING_INTERVAL_MS = 2000

const GOAL_STATUSES: ReadonlySet<string> = new Set([
  "active",
  "paused",
  "blocked",
  "usageLimited",
  "budgetLimited",
  "complete"
])

export const sessionGoalFrom = (value: unknown): SessionGoal | undefined => {
  if (!isRecord(value)) return undefined
  const objective = typeof value.objective === "string" ? value.objective : undefined
  const status =
    typeof value.status === "string" && GOAL_STATUSES.has(value.status)
      ? (value.status as GoalStatus)
      : undefined
  if (objective === undefined || status === undefined) return undefined
  return {
    createdAt: isoFromUnixSeconds(value.createdAt),
    objective,
    status,
    timeUsedSeconds: typeof value.timeUsedSeconds === "number" ? value.timeUsedSeconds : 0,
    tokenBudget: typeof value.tokenBudget === "number" ? value.tokenBudget : null,
    tokensUsed: typeof value.tokensUsed === "number" ? value.tokensUsed : 0,
    updatedAt: isoFromUnixSeconds(value.updatedAt)
  }
}

const isoFromUnixSeconds = (value: unknown): string =>
  new Date((typeof value === "number" ? value : 0) * 1000).toISOString()

const goalMateriallyChanged = (session: CodexSession, goal: SessionGoal): boolean =>
  session.lastEmittedGoal === undefined ||
  session.lastEmittedGoal.objective !== goal.objective ||
  session.lastEmittedGoal.status !== goal.status ||
  session.lastEmittedGoal.tokenBudget !== goal.tokenBudget

export const emitGoalSnapshot = (session: CodexSession, goal: SessionGoal): Promise<void> => {
  session.lastEmittedGoal = goal
  session.lastGoalEmitAtMs = Date.now()
  session.pendingGoalSnapshot = undefined
  return session.emit({
    kind: "session.updated",
    payload: { goal },
    subjectId: session.key
  })
}

export const emitGoalCleared = (session: CodexSession): Promise<void> => {
  session.lastEmittedGoal = undefined
  session.pendingGoalSnapshot = undefined
  return session.emit({
    kind: "session.updated",
    payload: { goalCleared: true },
    subjectId: session.key
  })
}

export const handleGoalUpdated = (
  session: CodexSession,
  payload: Record<string, unknown>
): void => {
  const goal = sessionGoalFrom(payload.goal)
  if (goal === undefined) return
  const outOfBand = payload.turnId === null || payload.turnId === undefined
  if (outOfBand || goalMateriallyChanged(session, goal)) {
    void emitGoalSnapshot(session, goal)
    return
  }
  if (Date.now() - session.lastGoalEmitAtMs >= GOAL_ACCOUNTING_INTERVAL_MS) {
    void emitGoalSnapshot(session, goal)
    return
  }
  session.pendingGoalSnapshot = goal
}

export const flushPendingGoalSnapshot = (session: CodexSession): Promise<void> => {
  const pending = session.pendingGoalSnapshot
  if (pending === undefined) return Promise.resolve()
  return emitGoalSnapshot(session, pending)
}
