import { mkdir, readFile, rename, writeFile } from "node:fs/promises"
import { dirname } from "node:path"

import { HarnessUsageLimits } from "@codevisor/api"
import { Option, Schema } from "effect"

export const USAGE_LIMITS_TTL_MS = 120_000

const UsageLimitsEntry = Schema.Struct({
  checkedAt: Schema.Number,
  limits: HarnessUsageLimits
})
type Entry = typeof UsageLimitsEntry.Type

const UsageLimitsDocument = Schema.Struct({
  version: Schema.Literal(1),
  entries: Schema.Record(Schema.String, UsageLimitsEntry)
})
const decodeDocument = Schema.decodeUnknownOption(UsageLimitsDocument)

const parseJson = (raw: string): unknown => {
  try {
    return JSON.parse(raw)
  } catch {
    return undefined
  }
}

export interface UsageLimitsStore {
  readonly load: () => Promise<ReadonlyMap<string, Entry>>
  readonly save: (entries: ReadonlyMap<string, Entry>) => Promise<void>
}

export const makeUsageLimitsFileStore = (path: string): UsageLimitsStore => ({
  load: async () => {
    const raw = await readFile(path, "utf8").catch(() => undefined)
    if (raw === undefined) return new Map()
    const parsed = Option.getOrUndefined(decodeDocument(parseJson(raw)))
    return new Map(Object.entries(parsed?.entries ?? {}))
  },
  save: async (entries) => {
    await mkdir(dirname(path), { recursive: true, mode: 0o700 })
    const temporary = `${path}.${process.pid}.tmp`
    await writeFile(
      temporary,
      JSON.stringify({ version: 1, entries: Object.fromEntries(entries) }),
      { encoding: "utf8", mode: 0o600 }
    )
    await rename(temporary, path)
  }
})

export interface UsageLimitsCache {
  readonly read: (
    key: string,
    fetch: () => Promise<HarnessUsageLimits>
  ) => Promise<HarnessUsageLimits>
  readonly observe: (key: string, limits: HarnessUsageLimits, partial: boolean) => void
}

export const usageLimitsKey = (harnessId: string, accountId: string | undefined) =>
  `${harnessId}:${accountId ?? "default"}`

const mergedWindows = (
  current: HarnessUsageLimits["windows"],
  observed: HarnessUsageLimits["windows"]
): HarnessUsageLimits["windows"] => [
  ...current.map((window) => observed.find((candidate) => candidate.id === window.id) ?? window),
  ...observed.filter((window) => !current.some((candidate) => candidate.id === window.id))
]

const unexpired = (limits: HarnessUsageLimits, now: number): HarnessUsageLimits | undefined => {
  if (limits.state !== "available") return limits
  const windows = limits.windows.filter(
    (window) => window.resetsAt === undefined || Date.parse(window.resetsAt) > now
  )
  if (windows.length === limits.windows.length) return limits
  return windows.length === 0 ? undefined : { ...limits, windows }
}

export const makeUsageLimitsCache = (
  options: {
    readonly now?: () => number
    readonly ttlMs?: number
    readonly store?: UsageLimitsStore
  } = {}
): UsageLimitsCache => {
  const now = options.now ?? Date.now
  const ttlMs = options.ttlMs ?? USAGE_LIMITS_TTL_MS
  const store = options.store
  const entries = new Map<string, Entry>()
  const inflight = new Map<string, Promise<HarnessUsageLimits>>()
  let saving: Promise<void> | undefined
  let dirty = false

  const loaded = (store?.load() ?? Promise.resolve(new Map<string, Entry>()))
    .then((stored) => {
      for (const [key, entry] of stored) if (!entries.has(key)) entries.set(key, entry)
    })
    .catch(() => undefined)

  const persist = () => {
    if (store === undefined) return
    dirty = true
    if (saving !== undefined) return
    const flush = async (): Promise<void> => {
      while (dirty) {
        dirty = false
        const available = new Map(
          [...entries].filter(([, entry]) => entry.limits.state === "available")
        )
        await store.save(available).catch(() => undefined)
      }
      saving = undefined
    }
    saving = flush()
  }

  const remember = (key: string, entry: Entry) => {
    entries.set(key, entry)
    persist()
  }

  const refresh = (key: string, fetch: () => Promise<HarnessUsageLimits>) => {
    const pending = fetch()
      .then((limits) => {
        const previous = entries.get(key)?.limits
        const kept =
          limits.state === "unavailable" && previous?.state === "available"
            ? (unexpired(previous, now()) ?? limits)
            : limits
        remember(key, { checkedAt: now(), limits: kept })
        return kept
      })
      .finally(() => inflight.delete(key))
    inflight.set(key, pending)
    return pending
  }

  return {
    read: async (key, fetch) => {
      await loaded
      const entry = entries.get(key)
      const current = entry === undefined ? undefined : unexpired(entry.limits, now())
      if (entry !== undefined && current !== undefined && now() - entry.checkedAt < ttlMs) {
        return current
      }
      return inflight.get(key) ?? refresh(key, fetch)
    },
    observe: (key, limits, partial) => {
      if (limits.state !== "available" || limits.windows.length === 0) return
      const entry = entries.get(key)
      if (!partial) {
        remember(key, { checkedAt: now(), limits: { ...entry?.limits, ...limits } })
        return
      }
      if (entry?.limits.state !== "available") return
      remember(key, {
        checkedAt: entry.checkedAt,
        limits: { ...entry.limits, windows: mergedWindows(entry.limits.windows, limits.windows) }
      })
    }
  }
}
