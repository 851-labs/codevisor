import {
  BrowserCookie,
  browserCookieKey,
  type BrowserCookieEntry,
  type BrowserCookieMutation,
  type BrowserCookieSnapshot
} from "@codevisor/api"
import { Schema } from "effect"

import type { CdpConnection } from "./browser-cdp.js"
import { recordsIn, type UnknownRecord } from "./unknown-values.js"

export type ExchangeBrowserCookies = (
  mutations: ReadonlyArray<BrowserCookieMutation>
) => Promise<BrowserCookieSnapshot>

export interface ManagedCookieSync {
  readonly synchronize: () => Promise<void>
  readonly stop: () => void
}

export const managedCookiePollMs = 2000

export const synchronizeManagedCookies = async (
  connection: CdpConnection,
  exchange: ExchangeBrowserCookies
): Promise<ManagedCookieSync> => {
  const mirror = cookieMirror(browserCookieJar(connection), exchange)
  const synchronize = coalesced(mirror.synchronize)
  await synchronize.run()
  return synchronize.poll(managedCookiePollMs)
}

const cookieMirror = (jar: BrowserCookieJar, exchange: ExchangeBrowserCookies) => {
  const revisions = new Map<string, number>()
  const rejected = new Map<string, number>()
  let baseline: Map<string, BrowserCookie> | undefined

  const importEntry = async (entry: BrowserCookieEntry, cookie: BrowserCookie) => {
    if (rejected.get(entry.key) === entry.revision) return
    if (await jar.write(cookie, entry.cookie === null)) rejected.delete(entry.key)
    else rejected.set(entry.key, entry.revision)
  }

  const reconcile = async (
    before: Cookies,
    next: Map<string, BrowserCookie>,
    snapshot: BrowserCookieSnapshot
  ) => {
    const now = await jar.read()
    const imported = new Set<string>()
    for (const entry of snapshot.entries) {
      revisions.set(entry.key, entry.revision)
      const local = now.get(entry.key)
      if (changedDuringExchange(local, before.get(entry.key))) {
        setOrDelete(next, entry.key, before.get(entry.key))
        continue
      }
      const change = browserChange(entry, local)
      if (change !== undefined) {
        await importEntry(entry, change)
        imported.add(entry.key)
      }
      setOrDelete(next, entry.key, entry.cookie ?? undefined)
    }
    await adoptBrowserCopies(jar, next, imported)
    return next
  }

  const exchangeOnce = async () => {
    const before = await jar.read()
    const known = baseline
    const mutations = known === undefined ? [] : changesSince(before, known, revisions)
    const snapshot = await exchange(mutations)
    baseline = await reconcile(before, new Map(known === undefined ? [] : before), snapshot)
  }

  return {
    synchronize: async () => {
      const bootstrapping = baseline === undefined
      await exchangeOnce()
      if (bootstrapping) await exchangeOnce()
    }
  }
}

const coalesced = (operation: () => Promise<void>) => {
  let stopped = false
  let pending: Promise<void> | undefined
  const run = (): Promise<void> => {
    if (stopped) return Promise.resolve()
    pending ??= operation().finally(() => {
      pending = undefined
    })
    return pending
  }
  const poll = (intervalMs: number): ManagedCookieSync => {
    const timer = setInterval(() => {
      run().catch(() => undefined)
    }, intervalMs)
    timer.unref()
    return {
      synchronize: run,
      stop: () => {
        stopped = true
        clearInterval(timer)
      }
    }
  }
  return { run, poll }
}

type Cookies = ReadonlyMap<string, BrowserCookie>

interface BrowserCookieJar {
  readonly read: () => Promise<Cookies>
  readonly write: (cookie: BrowserCookie, deleted: boolean) => Promise<boolean>
}

const browserCookieJar = (connection: CdpConnection): BrowserCookieJar => ({
  read: async () => {
    const result = await connection.send<{ cookies?: unknown }>("Storage.getCookies")
    return keyedCookies(recordsIn(result.cookies))
  },
  write: (cookie, deleted) =>
    connection.send("Storage.setCookies", { cookies: [cdpCookie(cookie, deleted)] }).then(
      () => true,
      () => false
    )
})

const keyedCookies = (raws: ReadonlyArray<UnknownRecord>): Cookies =>
  new Map(
    raws.flatMap((raw) => {
      const cookie = sharedCookie(raw)
      if (cookie === undefined) return []
      return [[browserCookieKey(cookie), cookie] as const]
    })
  )

const isSameSite = Schema.is(BrowserCookie.fields.sameSite)

const cookieSameSite = (value: unknown): BrowserCookie["sameSite"] => {
  const normalized = typeof value === "string" ? value.toLowerCase() : "unspecified"
  return isSameSite(normalized) ? normalized : "unspecified"
}

const partitioned = (raw: UnknownRecord): boolean =>
  Boolean(raw.partitionKey) || Boolean(raw.partitionKeyOpaque)

const sharedCookie = (raw: UnknownRecord): BrowserCookie | undefined => {
  if (partitioned(raw)) return undefined
  const { name, value, domain } = raw
  if (typeof name !== "string" || typeof value !== "string" || typeof domain !== "string")
    return undefined

  const cookie = {
    name,
    value,
    domain,
    path: typeof raw.path === "string" ? raw.path : "/",
    secure: raw.secure === true,
    httpOnly: raw.httpOnly === true,
    sameSite: cookieSameSite(raw.sameSite)
  }
  if (typeof raw.expires !== "number" || raw.expires <= 0) return cookie
  return { ...cookie, expires: raw.expires }
}

const deletedCookieExpiry = 1

const cdpCookie = (cookie: BrowserCookie, deleted: boolean): Record<string, unknown> => {
  const { sameSite, domain, ...rest } = cookie
  const projected: Record<string, unknown> = { ...rest }
  if (domain.startsWith(".")) projected.domain = domain
  else projected.url = `${cookie.secure ? "https" : "http"}://${domain}${cookie.path}`
  if (sameSite !== "unspecified")
    projected.sameSite = sameSite[0]!.toUpperCase() + sameSite.slice(1)
  if (deleted) projected.expires = deletedCookieExpiry
  return projected
}

const cookieFields = (cookie: BrowserCookie | null | undefined) => {
  if (cookie === null || cookie === undefined) return null
  const { name, value, domain, path, secure, httpOnly, sameSite, expires } = cookie
  return [name, value, domain, path, secure, httpOnly, sameSite, expires]
}

const sameCookie = (
  a: BrowserCookie | null | undefined,
  b: BrowserCookie | null | undefined
): boolean => JSON.stringify(cookieFields(a)) === JSON.stringify(cookieFields(b))

const changedDuringExchange = (
  now: BrowserCookie | undefined,
  before: BrowserCookie | undefined
): boolean => !sameCookie(now, before)

const browserChange = (
  entry: BrowserCookieEntry,
  local: BrowserCookie | undefined
): BrowserCookie | undefined => {
  if (sameCookie(local, entry.cookie)) return undefined
  return entry.cookie ?? local
}

const changesSince = (
  current: Cookies,
  baseline: Cookies,
  revisions: ReadonlyMap<string, number>
): BrowserCookieMutation[] =>
  [...new Set([...current.keys(), ...baseline.keys()])]
    .filter((key) => !sameCookie(current.get(key), baseline.get(key)))
    .map((key) => ({
      key,
      expectedRevision: revisions.get(key) ?? 0,
      cookie: current.get(key) ?? null
    }))

const setOrDelete = (
  cookies: Map<string, BrowserCookie>,
  key: string,
  cookie: BrowserCookie | undefined
): void => {
  if (cookie === undefined) cookies.delete(key)
  else cookies.set(key, cookie)
}

const adoptBrowserCopies = async (
  jar: BrowserCookieJar,
  baseline: Map<string, BrowserCookie>,
  imported: ReadonlySet<string>
): Promise<void> => {
  if (imported.size === 0) return
  const normalized = await jar.read()
  for (const key of imported) setOrDelete(baseline, key, normalized.get(key))
}
