import assert from "node:assert/strict"
import test from "node:test"

import {
  benchPlan,
  observedScenario,
  stepNotification,
  summarizeSwitches
} from "./dev-tab-switch-bench.mjs"

const described = (plan) => plan.map((step) => `${step.scenario}:${step.workspaceId ?? step.step}`)

test("visits every chat once, reopens the ones that fell out of the kept-alive set, then steps back and forth with the hotkey from a chat in the middle", () => {
  const plan = benchPlan(["a", "b", "c", "d"], 2, 3)

  assert.deepEqual(described(plan), [
    "first-visit:a",
    "first-visit:b",
    "first-visit:c",
    "first-visit:d",
    "evicted-reopen:a",
    "unmeasured:c",
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

test("with no more chats than are kept alive, nothing is reopened cold", () => {
  const plan = benchPlan(["a", "b"], 1, 5)

  assert.deepEqual(described(plan), [
    "first-visit:a",
    "first-visit:b",
    "unmeasured:b",
    "warm:-1",
    "warm:1"
  ])
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

test("a switch is labelled by whether the app had to build the page, not only by the plan", () => {
  assert.equal(observedScenario("first-visit", { values: { builtPage: 1 } }), "first-visit")
  assert.equal(observedScenario("evicted-reopen", { values: {} }), "warm")
  assert.equal(observedScenario("warm", { values: { builtPage: 1 } }), "evicted-reopen")
  assert.equal(observedScenario("warm", { values: {} }), "warm")
})
