import {
  browserCookieKey,
  type BrowserCookie,
  type BrowserCookieEntry,
  type BrowserCookieMutation
} from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"
import { Effect } from "effect"

import type { CdpConnection } from "./browser-cdp.js"

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
    path: String(raw.path ?? "/"),
    secure: raw.secure === true,
    httpOnly: raw.httpOnly === true,
    sameSite:
      typeof raw.sameSite === "string"
        ? (raw.sameSite.toLowerCase() as BrowserCookie["sameSite"])
        : "unspecified",
    ...(typeof raw.expires === "number" && raw.expires > 0 ? { expires: raw.expires } : {})
  }
}
const equal = (a: BrowserCookie | undefined | null, b: BrowserCookie | undefined | null) =>
  JSON.stringify(a ?? null) === JSON.stringify(b ?? null)

export const synchronizeManagedCookies = async (
  connection: CdpConnection,
  db: CodevisorDatabaseService
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
  // Chromium refuses some cookies other engines accept. Skip that one cookie:
  // failing would block every page and agent using this browser. The jar is read
  // back afterwards, so it is not published as deleted, and it is retried only
  // once the server has a new revision.
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
      for (const key of applied) {
        const cookie = normalized.get(key)
        if (cookie) baseline.set(key, cookie)
        else baseline.delete(key)
      }
    }
    const current = await read()
    const mutations: BrowserCookieMutation[] = [...new Set([...current.keys(), ...baseline.keys()])]
      .filter((key) => !equal(current.get(key), baseline!.get(key)))
      .map((key) => ({
        key,
        expectedRevision: revisions.get(key) ?? 0,
        cookie: current.get(key) ?? null
      }))
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
    for (const key of applied) {
      const cookie = normalized.get(key)
      if (cookie) next.set(key, cookie)
      else next.delete(key)
    }
    baseline = next
  }
  const sync = (): Promise<void> => {
    if (stopped || pending) return pending ?? Promise.resolve()
    pending = exchange().finally(() => {
      pending = undefined
    })
    return pending
  }
  // The first navigation must see the shared jar, including session cookies.
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
