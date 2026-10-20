import type { HarnessUsageLimits } from "@codevisor/api"

export type LimitState =
  | { readonly kind: "clear" }
  | { readonly kind: "blocked"; readonly resetsAt: Date }
  | { readonly kind: "blockedWithoutReset" }

export const resetGraceMs = 30_000
export const resumeStaggerMs = 15_000
export const maxUnknownResetChecks = 24

export const limitState = (limits: HarnessUsageLimits | undefined, now: number): LimitState => {
  const exhausted = exhaustedWindows(limits)
  if (exhausted.length === 0) return { kind: "clear" }

  const resetsAt = latestFutureReset(exhausted, now)
  if (resetsAt === undefined) return { kind: "blockedWithoutReset" }

  return { kind: "blocked", resetsAt }
}

export const futureReset = (resetsAt: string | undefined, now: number): Date | undefined => {
  if (resetsAt === undefined) return undefined

  const time = Date.parse(resetsAt)
  if (!(time > now)) return undefined

  return new Date(time)
}

export const checkAfterReset = (resetsAt: Date, now: number): Date =>
  new Date(Math.max(resetsAt.getTime(), now) + resetGraceMs)

export const checkAfterBackoff = (checks: number, now: number): Date =>
  new Date(now + Math.min(backoffBaseMs * 2 ** checks, backoffCapMs))

export const nextFireAt = (checkAt: string, lastResumeAt: number | undefined): number =>
  Math.max(Date.parse(checkAt), (lastResumeAt ?? 0) + resumeStaggerMs)

const backoffBaseMs = 5 * 60_000
const backoffCapMs = 60 * 60_000
const exhaustedPercent = 100

const exhaustedWindows = (limits: HarnessUsageLimits | undefined) =>
  limits?.state === "available"
    ? limits.windows.filter((window) => window.usedPercent >= exhaustedPercent)
    : []

const latestFutureReset = (
  windows: ReadonlyArray<HarnessUsageLimits["windows"][number]>,
  now: number
): Date | undefined => {
  const resets = windows.flatMap((window) => futureReset(window.resetsAt, now)?.getTime() ?? [])
  if (resets.length === 0) return undefined

  return new Date(Math.max(...resets))
}
