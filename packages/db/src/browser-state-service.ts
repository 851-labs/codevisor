import {
  BrowserCookiePeerCursor,
  BrowserNavigation,
  maxImportedBrowserCookies,
  shareableBrowserURL,
  type BrowserCookie,
  type BrowserCookieImportResult,
  type BrowserCookieMutation,
  type BrowserCookieSnapshot,
  type SharedBrowserCookie,
  type SharedBrowserCookieBatch
} from "@codevisor/api"
import { Schema, type Effect } from "effect"

import {
  applyBrowserCookieMutation,
  browserCookieShareRevision,
  browserCookieSnapshot,
  expireBrowserCookies,
  openBrowserCookieJar,
  saveBrowserCookieJar,
  type BrowserCookieJar
} from "./browser-cookie-jar.js"
import {
  importBrowserCookies,
  mergeSharedBrowserCookies,
  sharedBrowserCookiesAfter
} from "./browser-cookie-sharing.js"
import { instanceMetaSql, readInstanceMeta } from "./common-rows.js"
import { attempt, type DatabaseError } from "./errors.js"
import { parseJsonColumn } from "./json-column.js"
import type { ServiceContext } from "./service-context.js"

export interface BrowserStateService {
  readonly exchangeBrowserCookies: (
    mutations: ReadonlyArray<BrowserCookieMutation>
  ) => Effect.Effect<BrowserCookieSnapshot, DatabaseError>
  readonly importBrowserCookies: (
    cookies: ReadonlyArray<BrowserCookie>
  ) => Effect.Effect<BrowserCookieImportResult, DatabaseError>
  readonly browserCookieShareRevision: Effect.Effect<number, DatabaseError>
  readonly sharedBrowserCookiesAfter: (
    revision: number
  ) => Effect.Effect<SharedBrowserCookieBatch, DatabaseError>
  readonly mergeSharedBrowserCookies: (
    entries: ReadonlyArray<SharedBrowserCookie>
  ) => Effect.Effect<number, DatabaseError>
  readonly getBrowserCookiePeerCursor: (
    machineId: string
  ) => Effect.Effect<BrowserCookiePeerCursor, DatabaseError>
  readonly setBrowserCookiePeerCursor: (
    machineId: string,
    cursor: BrowserCookiePeerCursor
  ) => Effect.Effect<void, DatabaseError>
  readonly getBrowserNavigation: (
    paneId: string
  ) => Effect.Effect<BrowserNavigation | undefined, DatabaseError>
  readonly setBrowserNavigation: (
    paneId: string,
    navigation: BrowserNavigation
  ) => Effect.Effect<void, DatabaseError>
}

const maxCookieMutations = 20_000

export const makeBrowserStateService = ({
  sqlite,
  config
}: ServiceContext): BrowserStateService => {
  const read = <S extends Schema.Constraint>(key: string, schema: S): S["Type"] | undefined => {
    const value = readInstanceMeta(sqlite, key)
    return value === undefined ? undefined : parseJsonColumn(schema, value)
  }
  const write = (key: string, value: unknown) =>
    sqlite.prepare(instanceMetaSql.upsert).run(key, JSON.stringify(value))
  const withJar = <A>(change: (jar: BrowserCookieJar, nowMs: number) => A): A =>
    sqlite.transaction(() => {
      const nowMs = Date.now()
      const jar = openBrowserCookieJar(sqlite, config.serverId)
      expireBrowserCookies(jar, nowMs / 1000)
      const result = change(jar, nowMs)
      saveBrowserCookieJar(sqlite, jar)
      return result
    })()
  return {
    exchangeBrowserCookies: (mutations) =>
      attempt("exchangeBrowserCookies", () => {
        if (mutations.length > maxCookieMutations) throw new Error("Too many cookie changes")
        return withJar((jar, nowMs) => {
          for (const mutation of mutations) applyBrowserCookieMutation(jar, mutation, nowMs)
          return browserCookieSnapshot(jar)
        })
      }),
    importBrowserCookies: (cookies) =>
      attempt("importBrowserCookies", () => {
        if (cookies.length > maxImportedBrowserCookies) throw new Error("Too many cookies")
        return withJar((jar, nowMs) => importBrowserCookies(jar, cookies, nowMs))
      }),
    browserCookieShareRevision: attempt("browserCookieShareRevision", () =>
      browserCookieShareRevision(sqlite)
    ),
    sharedBrowserCookiesAfter: (revision) =>
      attempt("sharedBrowserCookiesAfter", () =>
        withJar((jar) => sharedBrowserCookiesAfter(jar, revision))
      ),
    mergeSharedBrowserCookies: (entries) =>
      attempt("mergeSharedBrowserCookies", () =>
        withJar((jar) => mergeSharedBrowserCookies(jar, entries))
      ),
    getBrowserCookiePeerCursor: (machineId) =>
      attempt(
        "getBrowserCookiePeerCursor",
        () => read(peerCursorKey(machineId), BrowserCookiePeerCursor) ?? { sent: 0, seen: 0 }
      ),
    setBrowserCookiePeerCursor: (machineId, cursor) =>
      attempt("setBrowserCookiePeerCursor", () => {
        write(peerCursorKey(machineId), cursor)
      }),
    getBrowserNavigation: (paneId) =>
      attempt("getBrowserNavigation", () =>
        read(`browser-navigation:${paneId}`, BrowserNavigation)
      ),
    setBrowserNavigation: (paneId, navigation) =>
      attempt("setBrowserNavigation", () => {
        if (!shareableBrowserURL(navigation.url)) return
        write(`browser-navigation:${paneId}`, {
          url: navigation.url,
          title: navigation.title.slice(0, 512)
        })
      })
  }
}

const peerCursorKey = (machineId: string): string => `browser-cookies-peer:${machineId}`
