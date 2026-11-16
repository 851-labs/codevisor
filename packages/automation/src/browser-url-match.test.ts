import { describe, expect, it } from "vitest"

import { urlMatcher } from "./browser-url-match.js"

const matches = (pattern: unknown, url: string) => urlMatcher(pattern, "url")(url)

describe("URL patterns", () => {
  it("matches a plain string only as the whole URL", () => {
    expect(matches("https://shop.test/cart?step=2", "https://shop.test/cart?step=2")).toBe(true)
    expect(matches("https://shop.test/cart", "https://shop.test/cart?step=2")).toBe(false)
  })

  it("lets * stay within a path segment and ** cross them", () => {
    expect(matches("**/api/*", "https://shop.test/v1/api/items")).toBe(true)
    expect(matches("**/api/*", "https://shop.test/v1/api/items/7")).toBe(false)
    expect(matches("https://shop.test/**", "https://shop.test/a/b?c=1")).toBe(true)
    expect(matches("**/*.{png,jpg}", "https://cdn.test/a/photo.jpg")).toBe(true)
    expect(matches("**/*.{png,jpg}", "https://cdn.test/a/photo.gif")).toBe(false)
    expect(matches("**/search?q=*", "https://shop.test/search?q=desk")).toBe(true)
    expect(matches("**/a.b", "https://shop.test/axb")).toBe(false)
  })

  it("tests a regular expression anywhere in the URL, the same way every time", () => {
    const pattern = { regex: String.raw`/orders/\d+$`, flags: "gi" }
    const matcher = urlMatcher(pattern, "url")
    expect([1, 2, 3].map(() => matcher("https://shop.test/ORDERS/42"))).toEqual([true, true, true])
    expect(matcher("https://shop.test/orders/new")).toBe(false)
  })

  it("rejects anything else, naming what is accepted", () => {
    expect(() => urlMatcher(42, "url")).toThrow(
      "url must be a URL, a glob pattern such as **/api/*, or a regular expression"
    )
  })
})
