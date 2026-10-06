import { describe, expect, it } from "vitest"

import { extensionConnectionReply } from "./browser-extension-status.js"
import { browserResultValue } from "./browser-repl.js"

describe("extension connection reply", () => {
  it("tells the agent what to do next, connected or not", () => {
    expect(browserResultValue(extensionConnectionReply(true))).toMatchObject({
      connected: true,
      connectionState: "connected",
      next: expect.stringContaining("openTabs")
    })
    expect(browserResultValue(extensionConnectionReply(false))).toMatchObject({
      connected: false,
      connectionState: "needs_setup",
      next: expect.stringContaining("not connected")
    })
  })
})
