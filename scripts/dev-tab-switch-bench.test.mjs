import assert from "node:assert/strict"
import test from "node:test"

import {
  benchPlan,
  benchReport,
  overLimits,
  parseLimits,
  stepNotification,
  summarizeSwitches
} from "./dev-tab-switch-bench.mjs"

const described = (plan) => plan.map((step) => `${step.scenario}:${step.workspaceId ?? step.step}`)

test("visits every chat once, goes back to each, then steps back and forth with the hotkey from a chat in the middle", () => {
  const plan = benchPlan(["a", "b", "c"], 2)

  assert.deepEqual(described(plan), [
    "first-visit:a",
    "first-visit:b",
    "first-visit:c",
    "revisit:a",
    "revisit:b",
    "revisit:c",
    "unmeasured:b",
    "warm:-1",
    "warm:1",
    "warm:-1",
    "warm:1"
  ])
})

test("a hotkey step is sent to one dev instance, by direction", () => {
  assert.equal(stepNotification("grits", -1), "com.851labs.codevisor.dev.tab-step.grits.previous")
  assert.equal(stepNotification("grits", 1), "com.851labs.codevisor.dev.tab-step.grits.next")
})

test("reports main-thread work, the first pass and the time to settle per scenario", () => {
  const switches = [
    { scenario: "warm", record: { durationMS: 10, values: { firstPassMS: 8, settleMS: 30 } } },
    { scenario: "warm", record: { durationMS: 20, values: { firstPassMS: 12, settleMS: 50 } } }
  ]

  assert.deepEqual(summarizeSwitches(switches), {
    "warm.busy": { count: 2, p50MS: 10, p95MS: 20, maxMS: 20 },
    "warm.firstPass": { count: 2, p50MS: 8, p95MS: 12, maxMS: 12 },
    "warm.settle": { count: 2, p50MS: 30, p95MS: 50, maxMS: 50 }
  })
})

const measured = {
  "revisit.busy": { count: 8, p50MS: 41, p95MS: 44, maxMS: 45 },
  "warm.busy": { count: 20, p50MS: 34, p95MS: 39, maxMS: 52 },
  "warm.settle": { count: 20, p50MS: 120, p95MS: 140, maxMS: 150 }
}

test("limits are read as scenario and milliseconds pairs", () => {
  assert.deepEqual(parseLimits("warm=60, revisit=90"), { warm: 60, revisit: 90 })
  assert.deepEqual(parseLimits(""), {})
  assert.throws(() => parseLimits("warm"), /--limits needs/)
  assert.throws(() => parseLimits("warm=fast"), /--limits needs/)
  assert.throws(() => parseLimits("warm=60=70"), /--limits needs/)
})

test("a scenario is over its limit when its median main-thread work is, or when it was never measured", () => {
  assert.deepEqual(overLimits(measured, { warm: 60, revisit: 90 }), [])
  assert.deepEqual(overLimits(measured, { warm: 30 }), [
    "warm: 34 ms of main-thread work per switch is over the 30 ms limit"
  ])
  assert.deepEqual(overLimits(measured, { "first-visit": 300 }), [
    "first-visit: no switches were measured"
  ])
})

test("the report has one row per scenario, measured or limited, with whether its limit was met", () => {
  assert.equal(
    benchReport(measured, { warm: 30, "first-visit": 300 }),
    [
      "| Switch | Count | Median ms | 95th percentile ms | Limit ms | Result |",
      "|---|---|---|---|---|---|",
      "| revisit | 8 | 41 | 44 |  |  |",
      "| warm | 20 | 34 | 39 | 30 | over |",
      "| first-visit | 0 |  |  | 300 | not measured |",
      ""
    ].join("\n")
  )
})
