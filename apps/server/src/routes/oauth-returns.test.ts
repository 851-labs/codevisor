import { describe, expect, it } from "vitest"

import { makeOAuthReturns } from "./oauth-returns.js"

describe("OAuth return apps", () => {
  it("returns to a Codevisor app once per sign-in and ignores other schemes", () => {
    const returns = makeOAuthReturns()

    for (const [state, app] of [
      ["s-1", "codevisor"],
      ["s-2", "codevisor-dev"],
      ["s-3", "codevisor-dev-0123456789"],
      ["s-4", "javascript"],
      ["s-5", 'codevisor"><script>'],
      ["s-6", "https"]
    ]) {
      returns.remember(`https://auth.example.test/authorize?state=${state}`, app)
    }
    returns.remember("https://auth.example.test/authorize", "codevisor")

    expect(["s-1", "s-2", "s-3", "s-4", "s-5", "s-6"].map(returns.take)).toEqual([
      "codevisor",
      "codevisor-dev",
      "codevisor-dev-0123456789",
      undefined,
      undefined,
      undefined
    ])
    expect(returns.take("s-1")).toBeUndefined()
  })

  it("forgets the oldest sign-ins once it holds too many", () => {
    const returns = makeOAuthReturns()

    for (let index = 0; index <= 64; index += 1) {
      returns.remember(`https://auth.example.test/authorize?state=s-${index}`, "codevisor")
    }

    expect([returns.take("s-0"), returns.take("s-1"), returns.take("s-64")]).toEqual([
      undefined,
      "codevisor",
      "codevisor"
    ])
  })
})
