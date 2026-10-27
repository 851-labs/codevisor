import { TypeError as CelTypeError } from "@marcbachmann/cel-js"
import { describe, expect, it } from "vitest"

import { describeCelError } from "./event-filter-errors.js"

describe("describeCelError", () => {
  it("falls back to a generic message when the checker reports no error", () => {
    expect(describeCelError(undefined, "a == 1", ["a"])).toBe("Filter is invalid.")
  })

  it("omits the location when the error has no source range", () => {
    expect(describeCelError(new CelTypeError("no such overload"), "a == 1", ["a"])).toBe(
      "no such overload."
    )
  })
})
