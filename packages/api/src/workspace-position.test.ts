import { Schema } from "effect"
import { describe, expect, it } from "vitest"

import {
  initialWorkspacePosition,
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
