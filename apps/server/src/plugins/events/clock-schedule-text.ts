import type { Cron } from "effect"

export const describeCron = (cron: Cron.Cron): string | undefined => {
  if (cron.months.size > 0) return undefined
  const days = dayPhrase(cron)
  if (days === undefined) return undefined

  const interval = intervalPhrase(cron)
  if (interval !== undefined) return `${interval}${days.during}`

  const times = timesPhrase(cron)
  if (times === undefined) return undefined
  return `${days.on} at ${times}`
}

interface DayPhrase {
  readonly on: string
  readonly during: string
}

const dayPhrase = (cron: Cron.Cron): DayPhrase | undefined => {
  const days = sorted(cron.days)
  const weekdays = sorted(cron.weekdays)
  if (days.length > 0 && weekdays.length > 0) return undefined
  if (days.length > 0) return monthDays(days)
  if (weekdays.length > 0) return weekDays(weekdays)
  return { on: "Daily", during: "" }
}

const monthDays = (days: ReadonlyArray<number>): DayPhrase => {
  const ordinals = joinList(days.map(ordinal))
  return { on: `Monthly on the ${ordinals}`, during: ` on the ${ordinals} of the month` }
}

const weekDays = (weekdays: ReadonlyArray<number>): DayPhrase => {
  const group = weekdayGroups[weekdays.join(",")]
  if (group !== undefined) return { on: group, during: ` on ${group.toLowerCase()}` }

  const named = joinList(weekdays.map((day) => `${weekdayNames[day]}s`))
  return { on: named, during: ` on ${named}` }
}

const intervalPhrase = (cron: Cron.Cron): string | undefined => {
  const seconds = sorted(cron.seconds)
  const minutes = sorted(cron.minutes)
  const hours = sorted(cron.hours)
  if (!onTheMinute(seconds)) return everySeconds(seconds, minutes, hours)
  if (hours.length === 0) return everyMinutes(minutes)
  return everyHours(hours, minutes)
}

const everySeconds = (
  seconds: ReadonlyArray<number>,
  minutes: ReadonlyArray<number>,
  hours: ReadonlyArray<number>
): string | undefined => {
  if (minutes.length > 0 || hours.length > 0) return undefined
  const step = stepOf(seconds, 60)
  return step === undefined ? undefined : every(step, "sec", "secs")
}

const everyMinutes = (minutes: ReadonlyArray<number>): string | undefined => {
  if (minutes.length === 1)
    return minutes[0] === 0 ? "Every hour" : `Every hour at :${pad(minutes[0]!)}`
  const step = stepOf(minutes, 60)
  return step === undefined ? undefined : every(step, "min", "mins")
}

const everyHours = (
  hours: ReadonlyArray<number>,
  minutes: ReadonlyArray<number>
): string | undefined => {
  if (hours.length < 2 || minutes.length !== 1) return undefined
  const step = stepOf(hours, 24)
  if (step === undefined) return undefined
  const base = every(step, "hour", "hrs")
  return minutes[0] === 0 ? base : `${base} at :${pad(minutes[0]!)}`
}

const timesPhrase = (cron: Cron.Cron): string | undefined => {
  const minutes = sorted(cron.minutes)
  const hours = sorted(cron.hours)
  if (!onTheMinute(sorted(cron.seconds)) || minutes.length === 0 || hours.length === 0)
    return undefined
  if (minutes.length * hours.length > maxListedTimes) return undefined
  return joinList(hours.flatMap((hour) => minutes.map((minute) => clockTime(hour, minute))))
}

const stepOf = (values: ReadonlyArray<number>, range: number): number | undefined => {
  if (values.length === 0) return 1
  if (values.length < 2 || values[0] !== 0) return undefined
  const step = values[1]!
  const even = values.every((value, index) => value === index * step)
  return even && values.length * step === range ? step : undefined
}

const onTheMinute = (seconds: ReadonlyArray<number>): boolean =>
  seconds.length === 1 && seconds[0] === 0

const every = (count: number, one: string, many: string): string =>
  count === 1 ? `Every ${one}` : `Every ${count} ${many}`

const clockTime = (hour: number, minute: number): string =>
  `${hour % 12 === 0 ? 12 : hour % 12}:${pad(minute)} ${hour < 12 ? "AM" : "PM"}`

const ordinal = (day: number): string => {
  const teen = day % 100 >= 11 && day % 100 <= 13
  const suffix = teen ? "th" : (ordinalSuffixes[day % 10] ?? "th")
  return `${day}${suffix}`
}

const joinList = (items: ReadonlyArray<string>): string => {
  if (items.length <= 2) return items.join(" and ")
  return `${items.slice(0, -1).join(", ")}, and ${items.at(-1)!}`
}

const sorted = (values: ReadonlySet<number>): ReadonlyArray<number> =>
  [...values].toSorted((left, right) => left - right)

const pad = (value: number): string => String(value).padStart(2, "0")

const maxListedTimes = 3

const weekdayGroups: Readonly<Record<string, string>> = {
  "1,2,3,4,5": "Weekdays",
  "0,6": "Weekends"
}

const ordinalSuffixes: Readonly<Record<number, string>> = { 1: "st", 2: "nd", 3: "rd" }

const weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
