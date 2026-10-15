import {
  BrowserCookie,
  browserCookieKey,
  type BrowserCookieEntry,
  type BrowserCookieMutation
} from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"
import { Effect, Schema } from "effect"

import type { CdpConnection } from "./browser-cdp.js"

const isSameSite = Schema.is(BrowserCookie.fields.sameSite)

const cookieSameSite = (value: unknown): BrowserCookie["sameSite"] => {
  const normalized = typeof value === "string" ? value.toLowerCase() : "unspecified"
  return isSameSite(normalized) ? normalized : "unspecified"
}

const normalize = (raw: Record<string, unknown>): BrowserCookie | undefined => {
  if (
    raw.partitionKey ||
    raw.partitionKeyOpaque ||
    typeof raw.name !== "string" ||
    typeof raw.value !== "string" ||
    typeof raw.domain !== "string"
  )
    return undefined
  return {
    name: raw.name,
    value: raw.value,
    domain: raw.domain,
    path: typeof raw.path === "string" ? raw.path : "/",
    secure: raw.secure === true,
    httpOnly: raw.httpOnly === true,
    sameSite: cookieSameSite(raw.sameSite),
    ...(typeof raw.expires === "number" && raw.expires > 0 ? { expires: raw.expires } : {})
  }
}
const equal = (a: BrowserCookie | undefined | null, b: BrowserCookie | undefined | null) =>
  JSON.stringify(a ?? null) === JSON.stringify(b ?? null)

const collectCookieMutations = (
  current: ReadonlyMap<string, BrowserCookie>,
  baseline: ReadonlyMap<string, BrowserCookie>,
  revisions: ReadonlyMap<string, number>
): BrowserCookieMutation[] =>
  [...new Set([...current.keys(), ...baseline.keys()])]
    .filter((key) => !equal(current.get(key), baseline.get(key)))
    .map((key) => ({
      key,
      expectedRevision: revisions.get(key) ?? 0,
      cookie: current.get(key) ?? null
    }))

const adoptNormalizedImports = (
  baseline: Map<string, BrowserCookie>,
  normalized: ReadonlyMap<string, BrowserCookie>,
  applied: ReadonlySet<string>
): void => {
  for (const key of applied) {
    const cookie = normalized.get(key)
    if (cookie) baseline.set(key, cookie)
    else baseline.delete(key)
  }
}

export const synchronizeManagedCookies = async (
  connection: CdpConnection,
  db: Pick<CodevisorDatabaseService, "exchangeBrowserCookies">
): Promise<{ synchronize: () => Promise<void>; stop: () => void }> => {
  let baseline: Map<string, BrowserCookie> | undefined
  const revisions = new Map<string, number>()
  let stopped = false
  let pending: Promise<void> | undefined
  const read = async () => {
    const result = await connection.send<{ cookies: Record<string, unknown>[] }>(
      "Storage.getCookies"
    )
    return new Map(
      result.cookies.flatMap((raw) => {
        const cookie = normalize(raw)
        return cookie ? [[browserCookieKey(cookie), cookie] as const] : []
      })
    )
  }
  const rejected = new Map<string, number>()
  const importEntry = async (entry: BrowserCookieEntry, cookie: BrowserCookie) => {
    if (rejected.get(entry.key) === entry.revision) return
    rejected.delete(entry.key)
    if (!(await apply(cookie, entry.cookie === null))) rejected.set(entry.key, entry.revision)
  }
  const apply = async (cookie: BrowserCookie, deleted: boolean) => {
    const { sameSite, domain, ...rest } = cookie
    return connection
      .send("Storage.setCookies", {
        cookies: [
          {
            ...rest,
            ...(domain.startsWith(".")
              ? { domain }
              : { url: `${cookie.secure ? "https" : "http"}://${domain}${cookie.path}` }),
            ...(sameSite === "unspecified"
              ? {}
              : { sameSite: sameSite[0]!.toUpperCase() + sameSite.slice(1) }),
            ...(deleted ? { expires: 1 } : {})
          }
        ]
      })
      .then(
        () => true,
        () => false
      )
  }
  const exchange = async () => {
    const local = await read()
    if (!baseline) {
      const snapshot = await Effect.runPromise(db.exchangeBrowserCookies([]))
      const now = await read()
      baseline = new Map()
      const applied = new Set<string>()
      for (const entry of snapshot.entries) {
        revisions.set(entry.key, entry.revision)
        if (!equal(now.get(entry.key), local.get(entry.key))) {
          const previous = local.get(entry.key)
          if (previous) baseline.set(entry.key, previous)
          continue
        }
        const cookie = entry.cookie ?? now.get(entry.key)
        if (cookie && !equal(now.get(entry.key), entry.cookie)) {
          await importEntry(entry, cookie)
          applied.add(entry.key)
        }
        if (entry.cookie) baseline.set(entry.key, entry.cookie)
      }
      const normalized = await read()
      adoptNormalizedImports(baseline, normalized, applied)
    }
    const current = await read()
    const mutations = collectCookieMutations(current, baseline, revisions)
    const snapshot = await Effect.runPromise(db.exchangeBrowserCookies(mutations))
    const now = await read()
    const next = new Map(current)
    const applied = new Set<string>()
    for (const entry of snapshot.entries) {
      revisions.set(entry.key, entry.revision)
      if (!equal(now.get(entry.key), current.get(entry.key))) continue
      const cookie = entry.cookie ?? now.get(entry.key)
      if (cookie && !equal(now.get(entry.key), entry.cookie)) {
        await importEntry(entry, cookie)
        applied.add(entry.key)
      }
      if (entry.cookie) next.set(entry.key, entry.cookie)
      else next.delete(entry.key)
    }
    const normalized = await read()
    adoptNormalizedImports(next, normalized, applied)
    baseline = next
  }
  const sync = (): Promise<void> => {
    if (stopped || pending) return pending ?? Promise.resolve()
    pending = exchange().finally(() => {
      pending = undefined
    })
    return pending
  }
  await sync()
  const timer = setInterval(() => {
    void sync().catch(() => undefined)
  }, 2000)
  timer.unref()
  return {
    synchronize: sync,
    stop: () => {
      stopped = true
      clearInterval(timer)
    }
  }
}
