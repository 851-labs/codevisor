import type { PluginEventType } from "@codevisor/api"

export const clockPlugin = "codevisor.clock"

const clockPayloadSchema = {
  type: "object",
  properties: {
    scheduledFor: { type: "string", description: "When this run was due (ISO 8601)." },
    firedAt: {
      type: "string",
      description:
        "When it actually fired. Later than scheduledFor if the machine was off or asleep."
    },
    missedRuns: {
      type: "integer",
      description: "Earlier runs of the schedule skipped while the machine was off or asleep."
    }
  }
}

const timezoneArgument = {
  type: "string",
  description: "IANA time zone, e.g. America/New_York. Defaults to this machine's time zone."
}

const delayArgument = (unit: string) => ({ type: "number", description: `${unit} to wait.` })

const clockType = (
  name: string,
  title: string,
  description: string,
  inputSchema: Record<string, unknown>
): PluginEventType => ({
  plugin: clockPlugin,
  pluginName: "Clock",
  name,
  title,
  description,
  delivery: [],
  inputSchema,
  payloadSchema: clockPayloadSchema
})

export const clockEventTypes: ReadonlyArray<PluginEventType> = [
  clockType(
    "after",
    "After a delay",
    "Wakes you once after a delay from now. arguments: any of seconds, minutes, hours, days (they add up), e.g. { minutes: 30 }.",
    {
      type: "object",
      properties: {
        seconds: delayArgument("Seconds"),
        minutes: delayArgument("Minutes"),
        hours: delayArgument("Hours"),
        days: delayArgument("Days")
      }
    }
  ),
  clockType(
    "at",
    "At a time",
    'Wakes you once at a date and time. arguments: at, e.g. "2026-11-14T09:00" (read in timezone unless it ends in Z or an offset), and optional timezone.',
    {
      type: "object",
      required: ["at"],
      properties: {
        at: { type: "string", description: "Date and time, ISO 8601." },
        timezone: timezoneArgument
      }
    }
  ),
  clockType(
    "every",
    "On a schedule",
    'Wakes you on a recurring cron schedule until you unsubscribe. arguments: cron (minute hour day-of-month month day-of-week, e.g. "0 9 * * 1-5" for weekdays at 9:00) and optional timezone. Runs missed while the machine was off or asleep fire once when it is back, with missedRuns.',
    {
      type: "object",
      required: ["cron"],
      properties: {
        cron: {
          type: "string",
          description: "Cron expression with 5 fields, or 6 with seconds first."
        },
        timezone: timezoneArgument
      }
    }
  )
]
