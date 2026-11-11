import { expect, it } from "vitest"

import { sharesBrowserCookie } from "./browser-cookie-sharing.js"

it.each([".github.com", "github.com", "accounts.Google.com", "foo.github.io"])(
  "shares sign-ins for public sites: %s",
  (domain) => {
    expect(sharesBrowserCookie(domain)).toBe(true)
  }
)

it.each([
  "localhost",
  ".localhost",
  "app.localhost",
  "printer.local",
  "db.internal",
  "router.home.arpa",
  "devbox",
  "127.0.0.1",
  "192.168.1.20",
  "[::1]",
  "::1"
])("keeps cookies for local hosts on their own machine: %s", (domain) => {
  expect(sharesBrowserCookie(domain)).toBe(false)
})
