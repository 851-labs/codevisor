export const DESKTOP_ENTRY = "desktop"
export const SCREEN_ENTRY = "screen"

export interface DisplayEntry {
  readonly id: string
  readonly vnc?: unknown
  readonly service?: unknown
}

export const displayEntries = (text: string | undefined): ReadonlyArray<DisplayEntry> => {
  const config = jsonObject(text)
  if (config === undefined) return []
  if (Array.isArray(config.displays)) return config.displays.filter(isAnEntry)
  if (config.vnc === undefined) return []

  return [{ id: DESKTOP_ENTRY, vnc: config.vnc, service: config.service }]
}

export const displayEntry = (text: string | undefined, id: string): DisplayEntry | undefined =>
  displayEntries(text).find((entry) => entry.id === id)

export const withDisplayEntry = (text: string | undefined, entry: DisplayEntry): string => {
  const others = displayEntries(text).filter((kept) => kept.id !== entry.id)
  return written(otherKeys(text), [...others, entry])
}

export const withoutDisplayEntry = (text: string | undefined, id: string): string | undefined => {
  const kept = displayEntries(text).filter((entry) => entry.id !== id)
  return kept.length === 0 ? undefined : written(otherKeys(text), kept)
}

const order = [DESKTOP_ENTRY, SCREEN_ENTRY]
const keysOfTheList = new Set(["displays", "vnc", "service"])

const written = (kept: Record<string, unknown>, entries: ReadonlyArray<DisplayEntry>): string => {
  const displays = entries.toSorted((one, other) => order.indexOf(one.id) - order.indexOf(other.id))
  return `${JSON.stringify({ ...kept, displays }, null, 2)}\n`
}

const otherKeys = (text: string | undefined): Record<string, unknown> =>
  Object.fromEntries(
    Object.entries(jsonObject(text) ?? {}).filter(([key]) => !keysOfTheList.has(key))
  )

const isAnEntry = (entry: unknown): entry is DisplayEntry =>
  typeof entry === "object" && entry !== null && "id" in entry && typeof entry.id === "string"

const jsonObject = (
  text: string | undefined
): { vnc?: unknown; service?: unknown; displays?: unknown } | undefined => {
  if (text === undefined) return undefined
  let parsed: unknown
  try {
    parsed = JSON.parse(text)
  } catch {
    return undefined
  }
  if (typeof parsed !== "object" || parsed === null) return undefined
  return parsed
}
