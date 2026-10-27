export interface EventSource {
  readonly serverId: string
  readonly accountId?: string | undefined
  readonly eventName: string
  readonly arguments: Readonly<Record<string, unknown>>
}

export const sourceKeyOf = (source: EventSource): string =>
  JSON.stringify([
    source.serverId,
    source.accountId ?? "",
    source.eventName,
    canonicalJson(source.arguments)
  ])

export const sourceOf = (source: EventSource): EventSource => ({
  serverId: source.serverId,
  ...(source.accountId === undefined ? {} : { accountId: source.accountId }),
  eventName: source.eventName,
  arguments: source.arguments
})

const canonicalJson = (value: unknown): string => JSON.stringify(sorted(value))

const sorted = (value: unknown): unknown => {
  if (Array.isArray(value)) return value.map(sorted)
  if (typeof value !== "object" || value === null) return value
  return Object.fromEntries(
    Object.entries(value)
      .toSorted(([left], [right]) => left.localeCompare(right))
      .map(([key, entry]) => [key, sorted(entry)])
  )
}
