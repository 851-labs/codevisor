import { describe, expect, it } from "vitest"

import {
  assistantTurnShowsActivityIndicator,
  assistantTurnSectionIsLockedOpen,
  assistantTurnDisclosureTransition,
  assistantTurnGoalActivity,
  goalActivityLabel,
  shouldCollapseSubagentDisclosure,
  subagentRendersAsSection,
  subagentDisclosureKey,
  turnDisclosureKey,
  turnImplementationDisclosureKey
} from "./AssistantTurn"

describe("goal activity", () => {
  it("uses the same concise ephemeral language as Thinking", () => {
    expect(goalActivityLabel("planning")).toBe("Planning…")
    expect(goalActivityLabel("verifying")).toBe("Verifying…")
  })

  it("stays generic until there is a response for the activity to follow", () => {
    expect(assistantTurnGoalActivity("", "planning")).toBeUndefined()
    expect(assistantTurnGoalActivity("Done.", "planning")).toBe("planning")
    expect(assistantTurnGoalActivity("Done.", "verifying")).toBe("verifying")
  })
})

const generatingItem = {
  id: "turn-1",
  role: "assistant" as const,
  text: "",
  createdAt: "2026-07-09T00:00:00.000Z",
  isGenerating: true
}

const emptyMeta = {
  startedAt: generatingItem.createdAt,
  thoughts: "",
  toolCalls: [],
  entries: [],
  subagents: {},
  textPhases: {},
  nextTextId: 0
}

describe("assistant activity indicator", () => {
  it("matches the native lull behavior after a tool settles", () => {
    const completedTool = {
      toolCallId: "read-1",
      title: "Read SessionView.swift",
      kind: "read",
      status: "completed"
    }
    expect(
      assistantTurnShowsActivityIndicator(generatingItem, {
        ...emptyMeta,
        toolCalls: [completedTool],
        entries: [{ type: "tool", call: completedTool }]
      })
    ).toBe(true)
  })

  it("defers to visible running tools and final text", () => {
    const runningTool = {
      toolCallId: "read-1",
      title: "Read SessionView.swift",
      kind: "read",
      status: "in_progress"
    }
    expect(
      assistantTurnShowsActivityIndicator(generatingItem, {
        ...emptyMeta,
        toolCalls: [runningTool],
        entries: [{ type: "tool", call: runningTool }]
      })
    ).toBe(false)
    expect(
      assistantTurnShowsActivityIndicator(
        { ...generatingItem, text: "Done." },
        {
          ...emptyMeta,
          entries: [{ type: "text", id: "final", markdown: "Done." }],
          textPhases: { final: "final" }
        }
      )
    ).toBe(false)
  })

  it("shows explicit thinking even while a tool is running", () => {
    const runningTool = {
      toolCallId: "read-1",
      status: "in_progress"
    }
    expect(
      assistantTurnShowsActivityIndicator(generatingItem, {
        ...emptyMeta,
        isThinking: true,
        toolCalls: [runningTool],
        entries: [{ type: "tool", call: runningTool }]
      })
    ).toBe(true)
    expect(
      assistantTurnShowsActivityIndicator(
        { ...generatingItem, isGenerating: false },
        { ...emptyMeta, isThinking: true }
      )
    ).toBe(false)
  })
})

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
    expect(assistantTurnDisclosureTransition({ ...settled, isGenerating: true }, settled)).toBe(
      "collapse"
    )
    expect(
      assistantTurnDisclosureTransition({ ...settled, hasRunningSubagent: true }, settled)
    ).toBe("collapse")
  })
})

describe("assistant turn disclosure interaction", () => {
  it("locks only a generating turn, not settled background subagent work", () => {
    expect(assistantTurnSectionIsLockedOpen(true, false)).toBe(true)
    expect(assistantTurnSectionIsLockedOpen(false, false)).toBe(false)
    expect(assistantTurnSectionIsLockedOpen(true, true)).toBe(false)
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

describe("subagent nesting", () => {
  it("matches the native two-section rendering cap", () => {
    expect(subagentRendersAsSection(0)).toBe(true)
    expect(subagentRendersAsSection(1)).toBe(true)
    expect(subagentRendersAsSection(2)).toBe(false)
  })
})
