import assert from "node:assert/strict"
import test from "node:test"

import {
  allowed,
  baselineOf,
  gateReport,
  indexEntry,
  method,
  parseIndex,
  regressions,
  withEntry
} from "./tab-switch-gate.mjs"

const run = (warm, warmP95 = warm + 3) => ({
  "warm.busy": { count: 20, p50MS: warm, p95MS: warmP95, maxMS: warmP95 },
  "warm.settle": { count: 20, p50MS: 200, p95MS: 230, maxMS: 290 }
})
const night = (warm, extra = {}) => ({ kind: "nightly", method, summary: run(warm), ...extra })
const steady = baselineOf([night(49), night(50), night(51)])

test("the baseline is the median of the last seven nightly runs measured the same way", () => {
  const nights = [40, 50, 50, 50, 50, 50, 50, 60].map((warm) => night(warm))
  const others = [night(900, { kind: "adhoc" }), night(900, { method: "older" })]

  const baseline = baselineOf([...nights, ...others])

  assert.equal(baseline.nights, 7)
  assert.deepEqual(baseline.scenarios.warm, { nights: 7, p50MS: 50, p95MS: 53 })
})

test("a median may rise by 15% or 3 ms, a 95th percentile by 20% or 5 ms, whichever is larger", () => {
  assert.equal(allowed(50, "p50MS"), 57.5)
  assert.equal(allowed(10, "p50MS"), 13)
  assert.equal(allowed(50, "p95MS"), 60)
  assert.equal(allowed(10, "p95MS"), 15)
})

test("a switch regresses only when every run is over the limit", () => {
  assert.deepEqual(regressions([run(58), run(59)], steady), [
    { scenario: "warm", measure: "p50MS" }
  ])
  assert.deepEqual(regressions([run(58), run(51)], steady), [])
  assert.deepEqual(regressions([run(51, 70), run(52, 71)], steady), [
    { scenario: "warm", measure: "p95MS" }
  ])
})

test("a switch that is no longer measured regresses", () => {
  const unmeasured = { "revisit.busy": run(50)["warm.busy"] }

  assert.deepEqual(regressions([unmeasured, unmeasured], steady), [
    { scenario: "warm", measure: "p50MS" },
    { scenario: "warm", measure: "p95MS" }
  ])
  assert.match(
    gateReport([unmeasured, unmeasured], steady),
    /\| warm \| Median \| .* \| not measured \|/
  )
  assert.deepEqual(regressions([unmeasured, run(50)], steady), [])
})

test("a switch new to the bench is not judged until it has three nightly runs of its own", () => {
  const added = { ...run(50), "revisit.busy": run(45)["warm.busy"] }
  const baseline = baselineOf([night(50), night(50), night(50), { ...night(50), summary: added }])
  const slow = { ...run(50), "revisit.busy": run(90)["warm.busy"] }

  assert.deepEqual(regressions([slow, slow], baseline), [])
  assert.match(
    gateReport([slow, slow], baseline),
    /\| revisit \| Median \| 90 \/ 90 \|  \|  \| no baseline yet \|/
  )
})

test("nothing is judged until the baseline has three nightly runs", () => {
  const filling = baselineOf([night(50), night(50)])

  assert.deepEqual(regressions([run(500), run(500)], filling), [])
  assert.match(gateReport([run(500)], filling), /no baseline yet/)
  assert.match(gateReport([run(500)], filling), /has 2 of the 3 nightly runs/)
})

test("the report shows each run against the baseline and its limit", () => {
  assert.equal(
    gateReport([run(58), run(51)], steady),
    [
      "| Switch | Measure | This run, ms | Baseline, ms | Limit, ms | Result |",
      "|---|---|---|---|---|---|",
      "| warm | Median | 58 / 51 | 50 | 57.5 | over in one run, ignored |",
      "| warm | 95th percentile | 61 / 54 | 53 | 63.6 | within |",
      "",
      "Judged against the median of the last 3 nightly runs that passed. A switch fails when every run is over the limit or it was not measured.",
      ""
    ].join("\n")
  )
  assert.match(
    gateReport([run(58), run(59)], steady),
    /\| warm \| Median \| 58 \/ 59 \| 50 \| 57.5 \| over in every run \|/
  )
})

test("a recorded night can be read back as a baseline night", () => {
  const entry = indexEntry(run(50), { id: "123", sha: "abc", date: "2026-11-19T12:23:00Z" })
  const read = parseIndex(`${JSON.stringify(entry)}\n\n`)

  assert.deepEqual(read, [entry])
  assert.equal(baselineOf(read).nights, 1)
})

test("a run is recorded once, on its own line", () => {
  const first = indexEntry(run(50), { id: "1", sha: "abc", date: "2026-11-19T12:23:00Z" })
  const second = indexEntry(run(51), { id: "2", sha: "def", date: "2026-11-20T12:23:00Z" })
  const unterminated = JSON.stringify(first)

  assert.deepEqual(parseIndex(withEntry(unterminated, second)), [first, second])
  assert.equal(withEntry(unterminated, first), unterminated)
  assert.equal(withEntry("", first), `${unterminated}\n`)
})
