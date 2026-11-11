import {
  BrowserCookieEntry,
  browserCookieKey,
  sharesBrowserCookie,
  SyncTimestamp,
  type BrowserCookie,
  type BrowserCookieMutation,
  type BrowserCookieSnapshot
} from "@codevisor/api"
import { compareSyncTimestamps, nextSyncTimestamp, type SyncTimestampValue } from "@codevisor/sync"
import type Database from "better-sqlite3"
import { Schema } from "effect"

import { instanceMetaSql, readInstanceMeta } from "./common-rows.js"
import { parseJsonColumn } from "./json-column.js"

export interface BrowserCookieJar {
  readonly entries: Map<string, BrowserCookieEntry>
  readonly stamps: Map<string, SyncTimestampValue>
  readonly deviceId: string
  readonly openedAt: number
  revision: number
  latestStamp: SyncTimestampValue | undefined
  sharedChanged: boolean
}

export const openBrowserCookieJar = (
  sqlite: Database.Database,
  deviceId: string
): BrowserCookieJar => {
  const stored = storedJar(sqlite)
  const stamps = new Map(Object.entries(stored.stamps ?? {}))
  return {
    entries: new Map(stored.entries.map((entry) => [entry.key, entry])),
    stamps,
    deviceId,
    openedAt: stored.revision,
    revision: stored.revision,
    latestStamp: latestStamp(stamps),
    sharedChanged: false
  }
}

export const saveBrowserCookieJar = (sqlite: Database.Database, jar: BrowserCookieJar): void => {
  if (jar.revision === jar.openedAt) return

  writeMeta(sqlite, jarKey, {
    revision: jar.revision,
    entries: [...jar.entries.values()],
    stamps: Object.fromEntries(jar.stamps)
  })
  if (jar.sharedChanged) writeMeta(sqlite, sharedRevisionKey, jar.revision)
}

export const browserCookieShareRevision = (sqlite: Database.Database): number => {
  const raw = readInstanceMeta(sqlite, sharedRevisionKey)
  return raw === undefined ? 0 : parseJsonColumn(Schema.Number, raw)
}

export const browserCookieSnapshot = (jar: BrowserCookieJar): BrowserCookieSnapshot => ({
  revision: jar.revision,
  entries: [...jar.entries.values()]
})

export const expireBrowserCookies = (jar: BrowserCookieJar, nowSeconds: number): void => {
  for (const entry of jar.entries.values()) {
    if (entry.cookie?.expires !== undefined && entry.cookie.expires <= nowSeconds) {
      jar.entries.set(entry.key, { key: entry.key, revision: ++jar.revision, cookie: null })
    }
  }
}

export const applyBrowserCookieMutation = (
  jar: BrowserCookieJar,
  mutation: BrowserCookieMutation,
  nowMs: number
): void => {
  const { cookie, key, expectedRevision } = mutation
  if (key.length > maxKeyLength || !Number.isSafeInteger(expectedRevision) || expectedRevision < 0)
    throw new Error("Invalid cookie revision or key")
  if (cookie) assertValidBrowserCookie(cookie, key)

  const previous = jar.entries.get(key)
  if ((previous?.revision ?? 0) !== expectedRevision) return
  if (previous && sameCookie(previous.cookie, cookie)) return

  setBrowserCookie(jar, key, cookie, localStamp(jar, key, nowMs))
}

export const setBrowserCookie = (
  jar: BrowserCookieJar,
  key: string,
  cookie: BrowserCookie | null,
  stamp: SyncTimestampValue | undefined
): void => {
  jar.entries.set(key, { key, revision: ++jar.revision, cookie })
  if (stamp === undefined) return

  jar.stamps.set(key, stamp)
  jar.latestStamp = laterStamp(jar.latestStamp, stamp)
  jar.sharedChanged = true
}

export const localStamp = (
  jar: BrowserCookieJar,
  key: string,
  nowMs: number
): SyncTimestampValue | undefined => {
  if (!sharesBrowserCookie(keyDomain(key))) return undefined
  return nextSyncTimestamp(jar.deviceId, jar.latestStamp, nowMs)
}

export const assertValidBrowserCookie = (cookie: BrowserCookie, key: string): void => {
  if (isValidBrowserCookie(cookie, key)) return
  throw new Error("Invalid cookie")
}

export const isValidBrowserCookie = (cookie: BrowserCookie, key: string): boolean =>
  browserCookieKey(cookie) === key &&
  cookie.domain !== "" &&
  cookie.path.startsWith("/") &&
  cookie.name.length + cookie.value.length <= maxCookieLength &&
  !/[\r\n\0]/.test(cookie.domain)

export const sameCookie = (a: BrowserCookie | null, b: BrowserCookie | null): boolean =>
  JSON.stringify(a) === JSON.stringify(b)

export const keyDomain = (key: string): string => {
  const parsed = parsedKey(key)
  return Array.isArray(parsed) && typeof parsed[0] === "string" ? parsed[0] : ""
}

const StoredBrowserCookieJar = Schema.Struct({
  revision: Schema.Number,
  entries: Schema.Array(BrowserCookieEntry),
  stamps: Schema.optional(Schema.Record(Schema.String, SyncTimestamp))
})

const jarKey = "browser-cookies-v1"
const sharedRevisionKey = "browser-cookies-shared-revision"
const maxKeyLength = 8192
const maxCookieLength = 16_384

const storedJar = (sqlite: Database.Database): typeof StoredBrowserCookieJar.Type => {
  const raw = readInstanceMeta(sqlite, jarKey)
  if (raw === undefined) return { revision: 0, entries: [] }
  return parseJsonColumn(StoredBrowserCookieJar, raw)
}

const latestStamp = (
  stamps: ReadonlyMap<string, SyncTimestampValue>
): SyncTimestampValue | undefined => [...stamps.values()].reduce(laterStamp, undefined)

const laterStamp = (
  latest: SyncTimestampValue | undefined,
  stamp: SyncTimestampValue
): SyncTimestampValue => {
  if (latest === undefined || compareSyncTimestamps(stamp, latest) > 0) return stamp
  return latest
}

const parsedKey = (key: string): unknown => {
  try {
    return JSON.parse(key) as unknown
  } catch {
    return undefined
  }
}

const writeMeta = (sqlite: Database.Database, key: string, value: unknown): void => {
  sqlite.prepare(instanceMetaSql.upsert).run(key, JSON.stringify(value))
}
