import { describe, expect, it } from "vitest"

import { compactRequest, isCompactPrompt } from "./compaction.js"

describe("compaction prompts", () => {
  it("reads /compact and its optional focus instructions", () => {
    expect(compactRequest("/compact")).toEqual({})
    expect(compactRequest("  /compact  \n")).toEqual({})
    expect(compactRequest("/compact keep the API notes\nand the plan")).toEqual({
      instructions: "keep the API notes\nand the plan"
    })
  })

  it("ignores other text and commands that only start the same way", () => {
    expect(compactRequest("please /compact")).toBeUndefined()
    expect(compactRequest("/compaction")).toBeUndefined()
    expect(compactRequest("/goal ship it")).toBeUndefined()
    expect([isCompactPrompt("/compact"), isCompactPrompt("compact")]).toEqual([true, false])
  })
})
