import { Schema } from "effect"

import { BrowserCookie } from "./browser-state.js"
import { SyncTimestamp } from "./sync.js"

export const FLEET_BROWSER_COOKIES_PATH = "fleet.browser_cookies"
export const maxSharedBrowserCookiesPerCall = 1_000
export const maxImportedBrowserCookies = 20_000

export const SharedBrowserCookie = Schema.Struct({
  key: Schema.String,
  cookie: Schema.NullOr(BrowserCookie),
  stamp: SyncTimestamp
})
export type SharedBrowserCookie = typeof SharedBrowserCookie.Type

export const SharedBrowserCookieBatch = Schema.Struct({
  revision: Schema.Number,
  more: Schema.Boolean,
  entries: Schema.Array(SharedBrowserCookie)
})
export type SharedBrowserCookieBatch = typeof SharedBrowserCookieBatch.Type

export const BrowserCookieShareRequest = Schema.Struct({
  since: Schema.Number,
  entries: Schema.Array(SharedBrowserCookie)
})
export type BrowserCookieShareRequest = typeof BrowserCookieShareRequest.Type

export const BrowserCookiePeerCursor = Schema.Struct({
  sent: Schema.Number,
  seen: Schema.Number
})
export type BrowserCookiePeerCursor = typeof BrowserCookiePeerCursor.Type

export const BrowserCookieImport = Schema.Struct({ cookies: Schema.Array(BrowserCookie) })
export type BrowserCookieImport = typeof BrowserCookieImport.Type

export const BrowserCookieImportResult = Schema.Struct({
  imported: Schema.Number,
  replaced: Schema.Number
})
export type BrowserCookieImportResult = typeof BrowserCookieImportResult.Type

export const sharesBrowserCookie = (domain: string): boolean => {
  const host = domain.replace(/^\./, "").toLowerCase()
  if (!host.includes(".") || host.includes(":")) return false
  if (localSuffixes.some((suffix) => host.endsWith(suffix))) return false
  return !ipv4Address.test(host)
}

const localSuffixes = [".localhost", ".local", ".internal", ".home.arpa"]
const ipv4Address = /^\d{1,3}(\.\d{1,3}){3}$/
