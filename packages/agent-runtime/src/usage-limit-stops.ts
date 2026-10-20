export interface UsageLimitStop {
  readonly stopKind: "usageLimit"
  readonly stopDetail: string
  readonly resetsAt?: string
}

export const usageLimitStop = (stopDetail: string, resetsAt?: Date): UsageLimitStop => ({
  stopKind: "usageLimit",
  stopDetail,
  ...(resetsAt === undefined ? {} : { resetsAt: resetsAt.toISOString() })
})

export const resetTimeIn = (text: string, now: Date = new Date()): Date | undefined => {
  const phrase = resetPhrase.exec(text)?.[1]
  if (phrase === undefined) return undefined

  const milliseconds = durationMilliseconds(phrase)
  if (milliseconds === 0) return undefined

  return new Date(now.getTime() + milliseconds)
}

export const epochResetTime = (
  value: unknown,
  unit: "seconds" | "milliseconds"
): Date | undefined => {
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) return undefined
  return new Date(unit === "seconds" ? value * millisecondsPerSecond : value)
}

const millisecondsPerSecond = 1000
const millisecondsPerMinute = 60 * millisecondsPerSecond
const millisecondsPerHour = 60 * millisecondsPerMinute
const millisecondsPerDay = 24 * millisecondsPerHour

const unitPattern = "ms|days?|d|hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s"

const durationPart = `\\d+(?:\\.\\d+)?\\s*(?:${unitPattern})(?![a-z])`

const resetPhrase = new RegExp(
  `\\b(?:resets?|try again|retry)\\s+(?:in|after)\\s+~?\\s*((?:${durationPart}[\\s,]*(?:and\\s+)?)+)`,
  "i"
)

const durationParts = new RegExp(`(\\d+(?:\\.\\d+)?)\\s*(${unitPattern})(?![a-z])`, "gi")

const durationMilliseconds = (phrase: string): number =>
  [...phrase.matchAll(durationParts)].reduce(
    (total, match) => total + Number(match[1]) * unitLength(String(match[2]).toLowerCase()),
    0
  )

const unitLength = (unit: string): number => {
  if (unit === "ms") return 1
  if (unit.startsWith("d")) return millisecondsPerDay
  if (unit.startsWith("h")) return millisecondsPerHour
  if (unit.startsWith("m")) return millisecondsPerMinute
  return millisecondsPerSecond
}
