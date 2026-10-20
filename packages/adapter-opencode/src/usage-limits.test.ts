import { describe, expect, it } from "vitest"

import { makeOpenCodeExtension } from "./extension.js"

const isUsageLimitFailure = (message: string): boolean | undefined =>
  makeOpenCodeExtension({
    emit: () => undefined,
    enqueueQuestion: () => new Promise(() => undefined)
  }).sdkConnectionCustomization?.isUsageLimitFailure?.({
    code: -32603,
    message: `Internal error: ${message}`,
    data: { service: "session", errorName: "APIError" }
  })

describe("OpenCode usage limits", () => {
  it.each([
    "The usage limit has been reached",
    "Quota exceeded. Check your plan and billing details.",
    "To use Codex with your ChatGPT plan, upgrade to Plus: https://openai.com/chatgpt/pricing."
  ])("treats a prompt OpenCode failed with %j as the account's usage limit", (message) => {
    expect(isUsageLimitFailure(message)).toBe(true)
  })

  it("keeps failing prompts the provider couldn't serve for other reasons", () => {
    expect(isUsageLimitFailure("Provider is overloaded")).toBe(false)
  })
})
