import type { AutomationProviderContext } from "./automation-provider.js"
import type { CodevisorApiToolSpec } from "./codevisor-api-tool-spec.js"
import { isPlainRecord } from "./unknown-values.js"

export const WAIT_REPLY_MARGIN_MS = 1_500
export const MIN_CLAMPED_WAIT_MS = 1_000

export interface BudgetedPayload {
  readonly payload: unknown
  readonly clampedToMs?: number
}

export const budgetedWaitPayload = (
  spec: CodevisorApiToolSpec,
  payload: unknown,
  context: AutomationProviderContext,
  now: () => number = () => performance.now()
): BudgetedPayload => {
  const wait = spec.budgetedWait
  if (wait === undefined || context.deadline === undefined || !isPlainRecord(payload)) {
    return { payload }
  }

  const requested = requestedMs(payload[wait.field], wait.defaultMs)
  const remaining = remainingBudgetMs(context.deadline, now())
  if (requested <= remaining || remaining < MIN_CLAMPED_WAIT_MS) return { payload }

  return { payload: { ...payload, [wait.field]: remaining }, clampedToMs: remaining }
}

export const withClampNote = (text: string, clampedToMs: number | undefined): string => {
  if (clampedToMs === undefined) return text
  const parsed: unknown = JSON.parse(text)
  if (!isPlainRecord(parsed)) return text
  return JSON.stringify({ ...parsed, clampedToMs })
}

const requestedMs = (value: unknown, defaultMs: number): number => {
  if (typeof value !== "number" || !Number.isFinite(value)) return defaultMs
  return Math.max(0, value)
}

export const remainingBudgetMs = (deadline: number, now: number): number =>
  Math.max(0, Math.floor(deadline - now - WAIT_REPLY_MARGIN_MS))
