import { createHash } from "node:crypto"

import type { CreatePluginEventSubscriptionRequest } from "@codevisor/api"

import { HttpFailure } from "../../server-context.js"
import type {
  BuiltinEventSource,
  BuiltinSourceRun,
  PreparedSubscription
} from "./builtin-event-sources.js"
import { clockDisplay, cronLabel } from "./clock-display.js"
import { clockEventTypes, clockPlugin } from "./clock-event-types.js"
import {
  cronSchedule,
  isTimeZone,
  oneShotSchedule,
  parseCron,
  parseLocalTime,
  type ClockSchedule,
  type DueRun
} from "./clock-schedules.js"
import type { EventOccurrence } from "./plugin-event-ingest.js"
import { sourceKeyOf, type EventSource } from "./plugin-event-source-key.js"

export interface ClockDeps {
  readonly now: () => number
  readonly timeZone: string
}

export const maxClockWaitMs = 60_000

export const makeClockEventSource = (deps: ClockDeps): BuiltinEventSource => ({
  plugin: clockPlugin,
  pluginName: "Clock",
  symbolName: "clock",
  types: clockEventTypes,
  prepare: (request) => prepareClock(deps, request),
  run: (source, run) => runClock(deps, source, run),
  display: clockDisplay
})

const prepareClock = (
  deps: ClockDeps,
  request: CreatePluginEventSubscriptionRequest
): PreparedSubscription => {
  const args = request.arguments ?? {}
  const timeZone = requireTimeZone(args.timezone ?? deps.timeZone)
  const prepare = preparers[request.event]
  if (prepare === undefined) throw badRequest(`no event "${request.event}"`)

  return prepare({ deps, request, args, timeZone })
}

interface ClockRequest {
  readonly deps: ClockDeps
  readonly request: CreatePluginEventSubscriptionRequest
  readonly args: Readonly<Record<string, unknown>>
  readonly timeZone: string
}

const prepareAfter = (clock: ClockRequest): PreparedSubscription =>
  oneShot(clock, afterDelay(clock.deps, clock.args))

const prepareAt = (clock: ClockRequest): PreparedSubscription =>
  oneShot(clock, atTime(clock.deps, clock.args, clock.timeZone))

const prepareEvery = ({ deps, request, args, timeZone }: ClockRequest): PreparedSubscription => {
  const cron = requireString(args.cron, "cron")
  requireCron(cron, timeZone)
  return {
    request: { ...request, arguments: { cron, timezone: timeZone, since: iso(deps.now()) } },
    explained: `${cronLabel(cron, timeZone)} (${timeZone})`
  }
}

const preparers: Readonly<Record<string, (clock: ClockRequest) => PreparedSubscription>> = {
  after: prepareAfter,
  at: prepareAt,
  every: prepareEvery
}

const oneShot = (
  { request, args, timeZone }: ClockRequest,
  dueAt: number
): PreparedSubscription => ({
  request: {
    ...request,
    arguments: { ...args, timezone: timeZone, dueAt: iso(dueAt) },
    once: true
  },
  explained: `Once at ${formatTime(dueAt, timeZone)}`
})

const runClock = async (
  deps: ClockDeps,
  source: EventSource,
  run: BuiltinSourceRun
): Promise<number> => {
  const schedule = scheduleOf(source)
  const now = deps.now()
  const due = schedule.due(cursorTime(await run.cursor()), now)
  if (due !== undefined) await fire(source, run, due, now)

  return waitFor(schedule.nextAfter(now), now)
}

const fire = async (
  source: EventSource,
  run: BuiltinSourceRun,
  due: DueRun,
  now: number
): Promise<void> => {
  await run.ingest([occurrence(source, due, now)])
  await run.saveCursor(iso(due.scheduledFor))
}

const occurrence = (source: EventSource, due: DueRun, now: number): EventOccurrence => ({
  eventId: `${sourceHash(source)}:${iso(due.scheduledFor)}`,
  name: source.eventName,
  timestamp: iso(due.scheduledFor),
  data: { scheduledFor: iso(due.scheduledFor), firedAt: iso(now), missedRuns: due.missedRuns }
})

const scheduleOf = (source: EventSource): ClockSchedule => {
  const args = source.arguments
  if (source.eventName !== "every") return oneShotSchedule(Date.parse(String(args.dueAt)))
  const cron = parseCron(String(args.cron), String(args.timezone))
  if (typeof cron === "string") throw new Error(cron)
  return cronSchedule(cron, Date.parse(String(args.since)))
}

const waitFor = (next: number | undefined, now: number): number => {
  if (next === undefined) return maxClockWaitMs
  return Math.min(Math.max(next - now, 0), maxClockWaitMs)
}

const afterDelay = (deps: ClockDeps, args: Readonly<Record<string, unknown>>): number => {
  const delayMs = delayOf(args)
  if (!(delayMs > 0)) throw badRequest("after needs a positive seconds, minutes, hours, or days")
  return deps.now() + delayMs
}

const delayOf = (args: Readonly<Record<string, unknown>>): number =>
  Object.entries(unitMs).reduce((total, [unit, ms]) => total + amountOf(args[unit], unit) * ms, 0)

const amountOf = (value: unknown, unit: string): number => {
  if (value === undefined) return 0
  if (typeof value === "number" && Number.isFinite(value) && value >= 0) return value
  throw badRequest(`${unit} must be a number of zero or more`)
}

const atTime = (
  deps: ClockDeps,
  args: Readonly<Record<string, unknown>>,
  timeZone: string
): number => {
  const text = requireString(args.at, "at")
  const dueAt = parseLocalTime(text, timeZone)
  if (dueAt === undefined)
    throw badRequest(`at "${text}" is not a date and time, e.g. 2026-11-14T09:00`)
  if (dueAt <= deps.now()) throw badRequest(`at "${text}" is in the past`)
  return dueAt
}

const requireCron = (cron: string, timeZone: string): void => {
  const parsed = parseCron(cron, timeZone)
  if (typeof parsed === "string") throw badRequest(`cron "${cron}": ${parsed}`)
}

const requireTimeZone = (value: unknown): string => {
  const timeZone = requireString(value, "timezone")
  if (!isTimeZone(timeZone))
    throw badRequest(`timezone "${timeZone}" is not an IANA time zone, e.g. America/New_York`)
  return timeZone
}

const requireString = (value: unknown, name: string): string => {
  if (typeof value === "string" && value.trim() !== "") return value.trim()
  throw badRequest(`${name} is required`)
}

const cursorTime = (cursor: string | undefined): number | undefined => {
  if (cursor === undefined) return undefined
  const time = Date.parse(cursor)
  return Number.isFinite(time) ? time : undefined
}

const formatTime = (time: number, timeZone: string): string =>
  new Intl.DateTimeFormat("en-US", { ...timeFormat, timeZone }).format(time)

const sourceHash = (source: EventSource): string =>
  createHash("sha256").update(sourceKeyOf(source)).digest("hex").slice(0, sourceHashLength)

const iso = (time: number): string => new Date(time).toISOString()

const badRequest = (message: string): HttpFailure => new HttpFailure(400, `Clock: ${message}`)

const sourceHashLength = 16

const timeFormat: Intl.DateTimeFormatOptions = {
  year: "numeric",
  month: "short",
  day: "numeric",
  hour: "numeric",
  minute: "2-digit",
  timeZoneName: "short"
}

const unitMs: Readonly<Record<string, number>> = {
  seconds: 1_000,
  minutes: 60_000,
  hours: 3_600_000,
  days: 86_400_000
}
