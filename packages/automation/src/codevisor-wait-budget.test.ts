import { describe, expect, it } from "vitest"

import { apiTool } from "./codevisor-api-tool-spec.js"
import { budgetedWaitPayload, withClampNote } from "./codevisor-wait-budget.js"

const waitSpec = apiTool("sessions.wait", "Wait", "POST", "/v1/sessions/wait", {
  budgetedWait: { field: "timeoutMs", defaultMs: 60_000 }
})
const now = () => 10_000

describe("wait budgets", () => {
  it("clamps an omitted timeout from its default and leaves a wait that fits alone", () => {
    const context = { sessionId: "s", deadline: 41_500 }

    expect(budgetedWaitPayload(waitSpec, { ids: ["a"] }, context, now)).toEqual({
      payload: { ids: ["a"], timeoutMs: 30_000 },
      clampedToMs: 30_000
    })
    expect(budgetedWaitPayload(waitSpec, { timeoutMs: 5_000 }, context, now)).toEqual({
      payload: { timeoutMs: 5_000 }
    })
  })

  it("lets a wait run on into a background job once the budget is nearly spent", () => {
    const spent = { sessionId: "s", deadline: 12_000 }

    expect(budgetedWaitPayload(waitSpec, { timeoutMs: 300_000 }, spent, now)).toEqual({
      payload: { timeoutMs: 300_000 }
    })
  })

  it("leaves calls without a deadline, a budgeted field, or an object body unchanged", () => {
    const plain = apiTool("sessions.get", "Get", "GET", "/v1/sessions/:id")

    expect(budgetedWaitPayload(waitSpec, { timeoutMs: 1 }, { sessionId: "s" }, now)).toEqual({
      payload: { timeoutMs: 1 }
    })
    expect(budgetedWaitPayload(plain, {}, { sessionId: "s", deadline: 0 }, now)).toEqual({
      payload: {}
    })
    expect(budgetedWaitPayload(waitSpec, ["x"], { sessionId: "s", deadline: 0 }, now)).toEqual({
      payload: ["x"]
    })
  })

  it("notes a clamp only on object responses", () => {
    expect(withClampNote('{"timedOut":true}', 0)).toBe('{"timedOut":true,"clampedToMs":0}')
    expect(withClampNote("[1]", 0)).toBe("[1]")
    expect(withClampNote('{"timedOut":true}', undefined)).toBe('{"timedOut":true}')
  })
})
