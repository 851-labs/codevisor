import { describe, expect, it } from "vitest"

import { makeAcpPermissionPolicy } from "./permission-policy.js"

const options = [
  { optionId: "once", name: "Allow once", kind: "allow_once" },
  { optionId: "always", name: "Always allow", kind: "allow_always" },
  { optionId: "reject", name: "Reject", kind: "reject_once" }
]
const request = (extra: Record<string, unknown> = {}) => ({
  sessionId: "s",
  toolCall: { toolCallId: "t", title: "/etc", kind: "read" },
  options,
  ...extra
})
const modes = (currentModeId: string) => ({
  currentModeId,
  availableModes: [
    { id: "build", name: "Build" },
    { id: "plan", name: "Plan", canonicalId: "plan" as const },
    { id: "read-only", name: "Read only", canonicalId: "readOnly" as const }
  ]
})
const selected = (optionId: string) => ({ outcome: { optionId, outcome: "selected" } })

describe("ACP permission policy", () => {
  it("allows once, without asking, in any mode that doesn't gate edits", () => {
    const policy = makeAcpPermissionPolicy()
    expect(policy.automaticOutcome(request())).toEqual(selected("once"))
    policy.sessionModes("s", modes("build"))
    expect(policy.automaticOutcome(request())).toEqual(selected("once"))
    // An agent offering only a lasting allow gets that.
    expect(policy.automaticOutcome(request({ options: options.slice(1) }))).toEqual(
      selected("always")
    )
  })

  it("asks in plan and read-only modes, and follows mode changes", () => {
    const policy = makeAcpPermissionPolicy()
    policy.sessionModes("s", modes("plan"))
    expect(policy.automaticOutcome(request())).toBeUndefined()
    policy.modeChanged("s", "build")
    expect(policy.automaticOutcome(request())).toEqual(selected("once"))
    policy.modeChanged("s", "read-only")
    expect(policy.automaticOutcome(request())).toBeUndefined()
    // A session reloaded without modes no longer remembers the old ones.
    policy.sessionModes("s", undefined)
    expect(policy.automaticOutcome(request())).toEqual(selected("once"))
    // A change for a session without modes has nothing to update.
    policy.modeChanged("s", "plan")
    expect(policy.automaticOutcome(request())).toEqual(selected("once"))
  })

  it("asks to leave plan mode, and when there's nothing to allow", () => {
    const policy = makeAcpPermissionPolicy()
    expect(
      policy.automaticOutcome(request({ toolCall: { toolCallId: "t", kind: "switch_mode" } }))
    ).toBeUndefined()
    expect(policy.automaticOutcome(request({ options: options.slice(2) }))).toBeUndefined()
    expect(policy.automaticOutcome(request({ options: undefined }))).toBeUndefined()
    expect(
      policy.automaticOutcome(request({ options: [{ kind: "allow_once" }, null] }))
    ).toBeUndefined()
    expect(policy.automaticOutcome(request({ sessionId: 1 }))).toBeUndefined()
    expect(policy.automaticOutcome(null)).toBeUndefined()
  })
})
