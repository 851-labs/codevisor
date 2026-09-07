import { expect, it } from "vitest"
import { browserCookieKey, shareableBrowserURL } from "./browser-state.js"

it("gives matching cookie identities the same key across browsers without colliding on path or name", () => {
  const cookie = { domain: ".EXAMPLE.com", path: "/account", name: "session" }
  expect(browserCookieKey(cookie)).toBe(browserCookieKey({ ...cookie, domain: "example.com" }))
  expect(browserCookieKey(cookie)).not.toBe(browserCookieKey({ ...cookie, path: "/" }))
  expect(browserCookieKey(cookie)).not.toBe(browserCookieKey({ ...cookie, name: "Session" }))
  expect(browserCookieKey({ domain: "example.com", path: "/a|b", name: "c" })).not.toBe(
    browserCookieKey({ domain: "example.com", path: "/a", name: "b|c" })
  )
})

it.each([
  "http://localhost:3000/search?q=emojis",
  "https://example.com/account#settings",
  "https://example.com/?redirect=/home#tab=profile"
])("shares a normal navigation: %s", (url) => {
  expect(shareableBrowserURL(url)).toBe(true)
})

it.each([
  "not a URL",
  "javascript:alert(1)",
  "file:///etc/hosts",
  "https://user@example.com/",
  "https://:password@example.com/",
  "https://example.com/callback?code=one-use",
  "https://example.com/callback?STATE=private",
  "https://example.com/#access_token=private",
  "https://example.com/#ID_TOKEN=private",
  "https://example.com/?refresh_token=private",
  "https://example.com/?oauth_token=private",
  "https://example.com/?oauth_verifier=private",
  "https://example.com/?code_verifier=private",
  "https://example.com/?SAMLResponse=private",
  "https://example.com/?session_state=private",
  "https://example.com/?password=private"
])("keeps credentials and authentication callbacks local: %s", (url) => {
  expect(shareableBrowserURL(url)).toBe(false)
})
