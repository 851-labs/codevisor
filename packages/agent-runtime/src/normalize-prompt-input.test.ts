import { describe, expect, it } from "vitest"

import { normalizePromptInput } from "./types.js"

describe("normalizePromptInput", () => {
  it("wraps bare strings and passes through structured input", () => {
    expect(normalizePromptInput("hello")).toEqual({ text: "hello" })
    expect(
      normalizePromptInput({
        text: "look",
        attachments: [
          {
            kind: "file",
            mimeType: "text/plain",
            name: "a.txt",
            path: "/tmp/a.txt",
            sizeBytes: 1
          }
        ]
      })
    ).toEqual({
      text: "look",
      attachments: [
        {
          kind: "file",
          mimeType: "text/plain",
          name: "a.txt",
          path: "/tmp/a.txt",
          sizeBytes: 1
        }
      ]
    })
  })
})
