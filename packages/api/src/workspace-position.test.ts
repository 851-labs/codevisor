import { Schema } from "effect"
import { describe, expect, it } from "vitest"

import {
  initialPanePosition,
  initialWorkspacePosition,
  nextPanePosition,
  workspacePositionBetween,
  WORKSPACE_POSITION_EPOCH_MAX,
  WorkspacePosition,
  workspacePositionEpoch
} from "./workspace-position.js"

const first = "00000000-0000-0000-0000-000000000001"
const second = "00000000-0000-0000-0000-000000000002"

describe("workspace position wire contract", () => {
  it("matches the native hex format and sorts simultaneous creations by identity", () => {
    expect(initialWorkspacePosition(0, first)).toBe(
      "ffffffffffff8000000000000000000000000000000018"
    )
    expect(initialWorkspacePosition(100, first) < initialWorkspacePosition(100, second)).toBe(true)
    expect(initialWorkspacePosition(101, second) < initialWorkspacePosition(100, first)).toBe(true)
    expect(workspacePositionEpoch(initialWorkspacePosition(1234.5, first))).toBe(1234)
    expect(workspacePositionEpoch(initialWorkspacePosition(-100, first))).toBe(0)
    expect(
      workspacePositionEpoch(initialWorkspacePosition(WORKSPACE_POSITION_EPOCH_MAX + 1, first))
    ).toBe(WORKSPACE_POSITION_EPOCH_MAX - 1)
  })

  it("encodes older non-UUID identities without introducing invalid rank digits", () => {
    const rank = initialWorkspacePosition(0, "workspace-1")
    expect(Schema.decodeUnknownSync(WorkspacePosition)(rank)).toBe(rank)
    expect(initialWorkspacePosition(0, "workspace-1")).not.toBe(
      initialWorkspacePosition(0, "workspace1")
    )
  })

  it("rejects noncanonical, oversized and non-ASCII keys", () => {
    const decode = Schema.decodeUnknownSync(WorkspacePosition)
    for (const value of ["", "invalid", "ffffffffffff0", "FFFFFFFFFFFF8", "f".repeat(1025)]) {
      expect(() => decode(value)).toThrow()
    }
  })
})

describe("positions between neighbours", () => {
  const third = "00000000-0000-0000-0000-000000000003"
  const lower = initialWorkspacePosition(200, first)
  const upper = initialWorkspacePosition(100, second)

  // The same vectors are asserted by the native WorkspacePosition tests, so a
  // server-assigned key and a client drag agree digit for digit.
  it("matches the native midpoint keys", () => {
    expect(workspacePositionBetween(lower, upper, third)).toBe(
      "ffffffffff68000000000000000000000000000000038"
    )
    expect(workspacePositionBetween(upper, undefined, third)).toBe(
      "ffffffffffc8000000000000000000000000000000038"
    )
    expect(workspacePositionBetween(undefined, lower, third)).toBe(
      "ffffffffff3748000000000000000000000000000000038"
    )
  })

  it("rejects bounds that are invalid or out of order", () => {
    expect(workspacePositionBetween(upper, lower, third)).toBeUndefined()
    expect(workspacePositionBetween("nope", undefined, third)).toBeUndefined()
    expect(workspacePositionBetween(undefined, "nope", third)).toBeUndefined()
  })

  it("starts an empty list after the newest possible creation time", () => {
    expect(workspacePositionBetween(undefined, undefined, third)).toBe(
      "ffffffffffff88000000000000000000000000000000038"
    )
  })

  it("gives up when no key fits within the length limit", () => {
    expect(workspacePositionBetween("f".repeat(1000), undefined, third)).toBeUndefined()
  })

  it("appends each new tab strictly after the last one", () => {
    const start = initialPanePosition(5000, first)
    const next = nextPanePosition(start, 1000, second)
    expect(next > start).toBe(true)
    expect(nextPanePosition(next, 9000, third) > next).toBe(true)
    expect(nextPanePosition(undefined, 1000, first)).toBe(initialPanePosition(1000, first))
  })
})
