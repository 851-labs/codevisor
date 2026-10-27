import { describe, expect, it } from "vitest"

import { substitutedArgs } from "./plugin-catalog-routes.js"

describe("package argument substitution", () => {
  it("fills placeholders and drops ones without a value", () => {
    expect(
      substitutedArgs(["-y", "tool", "--root", "${arg:1}", "${arg:2}"], { "1": "/tmp" })
    ).toEqual(["-y", "tool", "--root", "/tmp"])
  })
})
