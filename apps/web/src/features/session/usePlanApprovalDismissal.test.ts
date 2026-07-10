import { describe, expect, it } from "vitest"

import { dismissedPlanApprovalKey, rememberDismissedPlanApproval } from "./usePlanApprovalDismissal"

describe("plan approval dismissal", () => {
  it("retains each session dismissal across route remounts", () => {
    rememberDismissedPlanApproval("session-a", "assistant-a:plan-a")
    rememberDismissedPlanApproval("session-b", "assistant-b:plan-b")

    expect(dismissedPlanApprovalKey("session-a")).toBe("assistant-a:plan-a")
    expect(dismissedPlanApprovalKey("session-b")).toBe("assistant-b:plan-b")
  })

  it("can clear a retained dismissal", () => {
    rememberDismissedPlanApproval("session-clear", "assistant:plan")
    rememberDismissedPlanApproval("session-clear", undefined)

    expect(dismissedPlanApprovalKey("session-clear")).toBeUndefined()
  })
})
