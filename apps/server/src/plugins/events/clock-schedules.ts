import { Cron, DateTime, Option, Result } from "effect"

export interface DueRun {
  readonly scheduledFor: number
  readonly missedRuns: number
}

export interface ClockSchedule {
  readonly due: (firedThrough: number | undefined, now: number) => DueRun | undefined
  readonly nextAfter: (time: number) => number | undefined
}

export const maxCountedRuns = 1_000

export const oneShotSchedule = (dueAt: number): ClockSchedule => ({
  due: (firedThrough, now) => {
    if (firedThrough !== undefined || now < dueAt) return undefined
    return { scheduledFor: dueAt, missedRuns: 0 }
  },
  nextAfter: (time) => (time < dueAt ? dueAt : undefined)
})

export const cronSchedule = (cron: Cron.Cron, since: number): ClockSchedule => ({
  due: (firedThrough, now) => latestRun(cron, Math.max(firedThrough ?? since, since), now),
  nextAfter: (time) => Cron.next(cron, time).getTime()
})

export const parseCron = (expression: string, timeZone: string): Cron.Cron | string => {
  const parsed = Cron.parse(expression, timeZone)
  if (Result.isFailure(parsed)) return parsed.failure.message
  return parsed.success
}

export const parseLocalTime = (text: string, timeZone: string): number | undefined => {
  if (hasExplicitOffset(text)) return finiteOrUndefined(Date.parse(text))
  const zoned = DateTime.makeZoned(text, { timeZone, adjustForTimeZone: true })
  return Option.getOrUndefined(Option.map(zoned, DateTime.toEpochMillis))
}

export const isTimeZone = (timeZone: string): boolean =>
  Option.isSome(DateTime.zoneMakeNamed(timeZone))

const latestRun = (cron: Cron.Cron, after: number, now: number): DueRun | undefined => {
  let latest: number | undefined
  let count = 0
  for (
    let run = Cron.next(cron, after).getTime();
    run <= now;
    run = Cron.next(cron, run).getTime()
  ) {
    latest = run
    count += 1
    if (count === maxCountedRuns)
      return { scheduledFor: latestAtOrBefore(cron, now), missedRuns: count }
  }
  if (latest === undefined) return undefined
  return { scheduledFor: latest, missedRuns: count - 1 }
}

const latestAtOrBefore = (cron: Cron.Cron, now: number): number =>
  Cron.prev(cron, now + 1).getTime()

const hasExplicitOffset = (text: string): boolean => /(?:z|[+-]\d{2}:?\d{2})$/i.test(text.trim())

const finiteOrUndefined = (value: number): number | undefined =>
  Number.isFinite(value) ? value : undefined
