import { userInfo } from "node:os"

import { describe, expect, it } from "vitest"

import { maxDiagnosticTextLength, scrubDiagnosticText } from "./scrub.js"

describe("scrubDiagnosticText", () => {
  it.each([
    ["Couldn't open /Users/someone/code/secret-project/main.ts", "Couldn't open <path>"],
    ["git failed in ~/work/acme-repo: not a repository", "git failed in <path>: not a repository"],
    ["permission denied: /home/dev/.config/app.json", "permission denied: <path>"],
    ["contact person@example.com for access", "contact <email> for access"],
    ["401 with Bearer abc.def-123", "401 with Bearer <redacted>"],
    ["push rejected ghp_0123456789abcdefABCDEF", "push rejected <redacted>"],
    ["api_key=12345 rejected", "api_key=<redacted> rejected"],
    [
      "GET https://api.example.com/v1/models returned 500",
      "GET https://api.example.com/v1/models returned 500"
    ]
  ])("scrubs %j", (input, expected) => {
    expect(scrubDiagnosticText(input)).toBe(expected)
  })

  it("removes the user's name and caps long text", () => {
    expect(scrubDiagnosticText(`owner ${userInfo().username} lacks access`)).toBe(
      "owner <user> lacks access"
    )
    expect(scrubDiagnosticText("x".repeat(maxDiagnosticTextLength * 2))).toHaveLength(
      maxDiagnosticTextLength
    )
  })
})
