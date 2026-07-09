import { describe, expect, it } from "vitest"

import {
  subagentDisclosureKey,
  turnDisclosureKey,
  turnImplementationDisclosureKey
} from "./AssistantTurn"

describe("transcript disclosure keys", () => {
  it("uses stable keys matching the macOS transcript disclosure store cases", () => {
    expect(turnDisclosureKey("turn-1")).toBe("turn:turn-1")
    expect(turnImplementationDisclosureKey("turn-1")).toBe("turnImplementation:turn-1")
    expect(subagentDisclosureKey("tool-1")).toBe("subagent:tool-1")
  })
})
