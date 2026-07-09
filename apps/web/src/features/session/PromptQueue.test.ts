import { describe, expect, it } from "vitest"

import { queuedPromptUpdateText } from "./PromptQueue"

describe("queuedPromptUpdateText", () => {
  it("trims queued prompt edits like the macOS session model", () => {
    expect(queuedPromptUpdateText("  summarize next steps  ")).toBe("summarize next steps")
    expect(queuedPromptUpdateText("\n\t")).toBeUndefined()
  })
})
