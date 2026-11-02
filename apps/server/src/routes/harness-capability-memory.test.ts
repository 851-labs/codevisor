import { AgentRuntimeError } from "@codevisor/agent-runtime"
import type { HarnessCapability } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { harnesses } from "../test-support-stubs.js"
import {
  inspectionTimedOut,
  makeCapabilityMemory,
  REMEMBERED_CAPABILITY_LIMIT,
  type CapabilityRequest
} from "./harness-capability-memory.js"

const capability: HarnessCapability = { harness: harnesses[0]!, configOptions: [] }

const request = (overrides: Partial<CapabilityRequest> = {}): CapabilityRequest => ({
  harnessId: "codex",
  accountId: "shared-codex",
  cwd: "/repo",
  configSelections: undefined,
  ...overrides
})

const failure = (timedOut?: boolean) =>
  new AgentRuntimeError({
    operation: "inspectHarness",
    message: "failed",
    ...(timedOut === undefined ? {} : { timedOut })
  })

describe("capability memory", () => {
  it("recalls a capability for the same harness, account, folder and selections", () => {
    const memory = makeCapabilityMemory()
    memory.remember(request({ configSelections: { model: "gpt-5", effort: "high" } }), capability)

    expect(memory.recall(request({ configSelections: { effort: "high", model: "gpt-5" } }))).toBe(
      capability
    )
    expect(memory.recall(request({ accountId: "other-account" }))).toBeUndefined()
    expect(memory.recall(request({ cwd: "/other-repo" }))).toBeUndefined()
  })

  it("forgets the least recently checked folders past its limit", () => {
    const memory = makeCapabilityMemory()
    memory.remember(request({ cwd: "/repo-0" }), capability)
    for (let index = 1; index <= REMEMBERED_CAPABILITY_LIMIT; index += 1) {
      memory.remember(request({ cwd: `/repo-${index}` }), capability)
    }

    expect(memory.recall(request({ cwd: "/repo-0" }))).toBeUndefined()
    expect(memory.recall(request({ cwd: "/repo-1" }))).toBe(capability)
  })

  it("treats only inspection timeouts as timed out", () => {
    expect(inspectionTimedOut(failure(true))).toBe(true)
    expect(inspectionTimedOut(failure())).toBe(false)
    expect(inspectionTimedOut(new Error("timed out"))).toBe(false)
  })
})
