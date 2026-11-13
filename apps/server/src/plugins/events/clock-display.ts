import type { SubscriptionDisplay } from "./builtin-event-sources.js"
import { describeCron } from "./clock-schedule-text.js"
import { parseCron } from "./clock-schedules.js"
import type { EventSource } from "./plugin-event-source-key.js"

export const clockDisplay = (source: EventSource): SubscriptionDisplay => {
  const args = source.arguments
  const timeZone = String(args.timezone)
  if (source.eventName === "every") return { label: cronLabel(String(args.cron), timeZone) }

  const dueAt = String(args.dueAt)
  return { label: oneShotLabel(Date.parse(dueAt), timeZone), firesAt: dueAt }
}

export const cronLabel = (expression: string, timeZone: string): string => {
  const cron = parseCron(expression, timeZone)
  const described = typeof cron === "string" ? undefined : describeCron(cron)
  return described ?? `On the cron schedule "${expression}"`
}

export const oneShotLabel = (time: number, timeZone: string): string =>
  new Intl.DateTimeFormat("en-US", { ...oneShotFormat, timeZone }).format(time)

const oneShotFormat: Intl.DateTimeFormatOptions = {
  month: "short",
  day: "numeric",
  hour: "numeric",
  minute: "2-digit"
}
