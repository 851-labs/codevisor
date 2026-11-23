import { describe, expect, it } from "vitest"

import { makeDirectorySize } from "./directory-size.js"

describe("directory size", () => {
  it("reuses a measurement for a minute, then measures again", async () => {
    let clock = 0
    let measured = 0
    const size = makeDirectorySize(
      () => Promise.resolve(++measured),
      () => clock
    )

    expect(await size("/checkout")).toBe(1)
    clock = 59_999
    expect(await size("/checkout")).toBe(1)
    clock = 60_000
    expect(await size("/checkout")).toBe(2)
  })
})
