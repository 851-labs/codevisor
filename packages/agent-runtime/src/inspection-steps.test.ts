import { describe, expect, it } from "vitest"

import { makeInspectionStepLog } from "./inspection-steps.js"

const clockAt = (times: ReadonlyArray<number>) => {
  let index = 0
  return () => times[index++]!
}

describe("inspection step log", () => {
  it("names the step still running and how long each earlier step took", () => {
    const steps = makeInspectionStepLog(clockAt([0, 40, 340, 15_000]))

    steps.enter("spawn app-server")
    steps.enter("initialize")
    steps.enter("thread/start")

    expect(steps.describe()).toBe(
      "stuck in thread/start for 14660ms, after spawn app-server 40ms, initialize 300ms"
    )
  })

  it("describes a single step without earlier timings", () => {
    const steps = makeInspectionStepLog(clockAt([10, 25]))

    steps.enter("initialize")

    expect(steps.describe()).toBe("stuck in initialize for 15ms")
  })

  it("has nothing to describe when the adapter reported no steps", () => {
    expect(makeInspectionStepLog().describe()).toBeUndefined()
  })
})
