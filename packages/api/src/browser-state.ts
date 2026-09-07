import { Schema } from "effect"

// The jar belongs to this server installation, just like its connection token.
// Partitioned cookies are deliberately excluded: WebKit cannot round-trip their key.
export const BrowserCookie = Schema.Struct({
  name: Schema.String,
  value: Schema.String,
  domain: Schema.String,
  path: Schema.String,
  secure: Schema.Boolean,
  httpOnly: Schema.Boolean,
  sameSite: Schema.Literals(["unspecified", "none", "lax", "strict"]),
  expires: Schema.optional(Schema.Number)
})
export type BrowserCookie = typeof BrowserCookie.Type
export const BrowserCookieMutation = Schema.Struct({
  key: Schema.String,
  expectedRevision: Schema.Number,
  cookie: Schema.NullOr(BrowserCookie)
})
export type BrowserCookieMutation = typeof BrowserCookieMutation.Type
export const BrowserCookieEntry = Schema.Struct({
  key: Schema.String,
  revision: Schema.Number,
  cookie: Schema.NullOr(BrowserCookie)
})
export type BrowserCookieEntry = typeof BrowserCookieEntry.Type
export const BrowserCookieSnapshot = Schema.Struct({
  revision: Schema.Number,
  entries: Schema.Array(BrowserCookieEntry)
})
export type BrowserCookieSnapshot = typeof BrowserCookieSnapshot.Type
export const BrowserCookieExchange = Schema.Struct({
  mutations: Schema.Array(BrowserCookieMutation)
})
export const BrowserNavigation = Schema.Struct({ url: Schema.String, title: Schema.String })
export type BrowserNavigation = typeof BrowserNavigation.Type

export const browserCookieKey = (cookie: Pick<BrowserCookie, "domain" | "path" | "name">): string =>
  JSON.stringify([cookie.domain.replace(/^\./, "").toLowerCase(), cookie.path, cookie.name])

export const shareableBrowserURL = (address: string): boolean => {
  try {
    const url = new URL(address)
    if (!["http:", "https:"].includes(url.protocol) || url.username || url.password) return false
    const secrets = new Set([
      "code",
      "state",
      "access_token",
      "id_token",
      "refresh_token",
      "oauth_token",
      "oauth_verifier",
      "code_verifier",
      "samlresponse",
      "session_state",
      "password"
    ])
    return ![...url.searchParams.keys(), ...new URLSearchParams(url.hash.slice(1)).keys()].some(
      (key) => secrets.has(key.toLowerCase())
    )
  } catch {
    return false
  }
}
