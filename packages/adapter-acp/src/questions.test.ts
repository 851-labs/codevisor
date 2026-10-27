import { describe, expect, it } from "vitest"

import { acpPermissionDecline, acpRejectOptionId } from "./questions.js"

describe("ACP permission replies", () => {
  it("declines with the agent's reject-once option before reject-always", () => {
    const rejectOptionId = acpRejectOptionId([
      { kind: "allow_once", optionId: "allow" },
      { kind: "reject_always", optionId: "never" },
      { kind: "reject_once", optionId: "not-now" }
    ])

    expect(acpPermissionDecline(rejectOptionId)).toEqual({
      delivered: false,
      response: { outcome: { optionId: "not-now", outcome: "selected" } }
    })
  })

  it("falls back to reject-always when the agent offers no reject-once option", () => {
    const rejectOptionId = acpRejectOptionId([
      { kind: "allow_always", optionId: "always" },
      { kind: "reject_always", optionId: "never" }
    ])

    expect(acpPermissionDecline(rejectOptionId).response).toEqual({
      outcome: { optionId: "never", outcome: "selected" }
    })
  })

  it("cancels the request when the agent offers no reject option", () => {
    const rejectOptionId = acpRejectOptionId([{ kind: "allow_once", optionId: "allow" }])

    expect(acpPermissionDecline(rejectOptionId)).toEqual({
      delivered: false,
      response: { outcome: { outcome: "cancelled" } }
    })
  })
})
