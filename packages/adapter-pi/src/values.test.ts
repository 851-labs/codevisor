import { describe, expect, it } from "vitest"

import { errorMessage } from "./values.js"

describe("errorMessage", () => {
  it("reads an Error's message and stringifies anything else", () => {
    expect(errorMessage(new Error("boom"))).toBe("boom")
    expect(errorMessage("plain failure")).toBe("plain failure")
  })
})
