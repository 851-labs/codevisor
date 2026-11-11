import {
  browserCookieKey,
  maxSharedBrowserCookiesPerCall,
  sharesBrowserCookie,
  type BrowserCookie,
  type BrowserCookieImportResult,
  type BrowserCookieEntry,
  type SharedBrowserCookie,
  type SharedBrowserCookieBatch
} from "@codevisor/api"
import { compareSyncTimestamps, type SyncTimestampValue } from "@codevisor/sync"

import {
  isValidBrowserCookie,
  keyDomain,
  localStamp,
  sameCookie,
  setBrowserCookie,
  type BrowserCookieJar
} from "./browser-cookie-jar.js"

export const sharedBrowserCookiesAfter = (
  jar: BrowserCookieJar,
  after: number
): SharedBrowserCookieBatch => {
  const since = after > jar.revision ? 0 : after
  const changed = [...jar.entries.values()]
    .filter((entry) => entry.revision > since && isShared(jar, entry))
    .toSorted((a, b) => a.revision - b.revision)
  const batch = changed.slice(0, maxSharedBrowserCookiesPerCall)
  const more = changed.length > batch.length

  return {
    revision: more ? batch.at(-1)!.revision : jar.revision,
    more,
    entries: batch.map((entry) => sharedCookie(jar, entry))
  }
}

export const mergeSharedBrowserCookies = (
  jar: BrowserCookieJar,
  incoming: ReadonlyArray<SharedBrowserCookie>
): number => {
  let merged = 0
  for (const shared of incoming) {
    if (!acceptsSharedCookie(shared)) continue
    if (!isNewer(shared.stamp, stampOf(jar, shared.key))) continue

    setBrowserCookie(jar, shared.key, shared.cookie, shared.stamp)
    merged += 1
  }
  return merged
}

export const importBrowserCookies = (
  jar: BrowserCookieJar,
  cookies: ReadonlyArray<BrowserCookie>,
  nowMs: number
): BrowserCookieImportResult => {
  const imported = new Map(
    cookies.filter((cookie) => sharesBrowserCookie(cookie.domain)).map(keyed)
  )
  const sites = importedSites([...imported.values()])
  const replaced = clearSites(jar, sites, imported, nowMs)
  for (const [key, cookie] of imported) writeImported(jar, key, cookie, nowMs)
  return { imported: imported.size, replaced }
}

const isShared = (jar: BrowserCookieJar, entry: BrowserCookieEntry): boolean =>
  sharesBrowserCookie(keyDomain(entry.key)) && (entry.cookie !== null || jar.stamps.has(entry.key))

const sharedCookie = (jar: BrowserCookieJar, entry: BrowserCookieEntry): SharedBrowserCookie => ({
  key: entry.key,
  cookie: entry.cookie,
  stamp: stampOf(jar, entry.key) ?? unstamped(jar)
})

const stampOf = (jar: BrowserCookieJar, key: string): SyncTimestampValue | undefined => {
  const stamp = jar.stamps.get(key)
  if (stamp !== undefined || !jar.entries.has(key)) return stamp
  return unstamped(jar)
}

const unstamped = (jar: BrowserCookieJar): SyncTimestampValue => ({
  wallMs: 0,
  counter: 0,
  deviceId: jar.deviceId
})

const acceptsSharedCookie = (shared: SharedBrowserCookie): boolean => {
  if (!sharesBrowserCookie(keyDomain(shared.key))) return false
  return shared.cookie === null || isValidBrowserCookie(shared.cookie, shared.key)
}

const isNewer = (stamp: SyncTimestampValue, current: SyncTimestampValue | undefined): boolean =>
  current === undefined || compareSyncTimestamps(stamp, current) > 0

const keyed = (cookie: BrowserCookie): [string, BrowserCookie] => [browserCookieKey(cookie), cookie]

const importedSites = (cookies: ReadonlyArray<BrowserCookie>): ImportedSites => {
  const domains = new Set(cookies.map((cookie) => hostOf(cookie.domain)))
  const parents = new Set([...domains].flatMap(parentDomains))
  return { domains, parents }
}

interface ImportedSites {
  readonly domains: ReadonlySet<string>
  readonly parents: ReadonlySet<string>
}

const clearSites = (
  jar: BrowserCookieJar,
  sites: ImportedSites,
  imported: ReadonlyMap<string, BrowserCookie>,
  nowMs: number
): number => {
  let cleared = 0
  for (const entry of jar.entries.values()) {
    if (entry.cookie === null || imported.has(entry.key)) continue
    if (!belongsToSites(hostOf(entry.cookie.domain), sites)) continue

    setBrowserCookie(jar, entry.key, null, localStamp(jar, entry.key, nowMs))
    cleared += 1
  }
  return cleared
}

const belongsToSites = (host: string, sites: ImportedSites): boolean =>
  sites.parents.has(host) || [host, ...parentDomains(host)].some((name) => sites.domains.has(name))

const writeImported = (
  jar: BrowserCookieJar,
  key: string,
  cookie: BrowserCookie,
  nowMs: number
): void => {
  if (!isValidBrowserCookie(cookie, key)) return
  if (sameCookie(jar.entries.get(key)?.cookie ?? null, cookie)) return

  setBrowserCookie(jar, key, cookie, localStamp(jar, key, nowMs))
}

const hostOf = (domain: string): string => domain.replace(/^\./, "").toLowerCase()

const parentDomains = (host: string): ReadonlyArray<string> => {
  const labels = host.split(".")
  return labels.slice(1, -1).map((_, index) => labels.slice(index + 1).join("."))
}
