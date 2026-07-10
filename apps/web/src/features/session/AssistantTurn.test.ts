import { describe, expect, it } from "vitest"

import {
  assistantTurnDisclosureTransition,
  shouldCollapseSubagentDisclosure,
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

describe("assistant turn disclosure transitions", () => {
  const settled = {
    isGenerating: false,
    isFinalAsserted: true,
    hasRunningSubagent: false
  }

  it("does not overwrite stored disclosure state when a settled turn remounts", () => {
    expect(assistantTurnDisclosureTransition(settled, settled)).toBeUndefined()
  })

  it("expands when a settled turn starts generating again", () => {
    expect(
      assistantTurnDisclosureTransition(settled, {
        ...settled,
        isGenerating: true,
        isFinalAsserted: false
      })
    ).toBe("expand")
  })

  it("collapses when generation or the final background subagent finishes", () => {
    expect(
      assistantTurnDisclosureTransition(
        { ...settled, isGenerating: true },
        settled
      )
    ).toBe("collapse")
    expect(
      assistantTurnDisclosureTransition(
        { ...settled, hasRunningSubagent: true },
        settled
      )
    ).toBe("collapse")
  })
})

describe("subagent disclosure transitions", () => {
  it("does not overwrite stored disclosure state on a settled remount", () => {
    expect(shouldCollapseSubagentDisclosure(false, false)).toBe(false)
  })

  it("collapses only when a running subagent settles", () => {
    expect(shouldCollapseSubagentDisclosure(true, false)).toBe(true)
    expect(shouldCollapseSubagentDisclosure(true, true)).toBe(false)
  })
})
