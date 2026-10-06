import { describe, expect, it } from "vitest"

import { backgroundTerminalKey } from "./background-terminals.js"

describe("backgroundTerminalKey", () => {
  it("namespaces task terminals under the session key", () => {
    expect(backgroundTerminalKey("session-1", "task-9")).toBe("session-1:bg:task-9")
  })
})
