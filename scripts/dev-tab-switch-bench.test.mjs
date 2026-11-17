import assert from "node:assert/strict"
import test from "node:test"

import { benchPlan, summarizeSwitches } from "./dev-tab-switch-bench.mjs"

test("visits every chat once, reopens only the ones that fell out of the kept-alive set, then alternates the last two", () => {
  const plan = benchPlan(["a", "b", "c", "d"], 2, 3)

  assert.deepEqual(
    plan.map((step) => `${step.scenario}:${step.workspaceId}`),
    [
      "first-visit:a",
      "first-visit:b",
      "first-visit:c",
      "first-visit:d",
      "evicted-reopen:a",
      "warm:d",
      "warm:a",
      "warm:d",
      "warm:a"
    ]
  )
})

test("with no more chats than are kept alive, nothing is reopened cold", () => {
  const plan = benchPlan(["a", "b"], 1, 5)

  assert.deepEqual(
    plan.map((step) => `${step.scenario}:${step.workspaceId}`),
    ["first-visit:a", "first-visit:b", "warm:a", "warm:b"]
  )
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
