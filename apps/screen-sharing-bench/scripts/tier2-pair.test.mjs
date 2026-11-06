import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"
import { fileURLToPath } from "node:url"

const script = fileURLToPath(new URL("./tier2-pair.sh", import.meta.url))

const fakeCurl = `#!/usr/bin/env node
const fs = require("node:fs")
fs.appendFileSync(process.env.FAKE_CALLS, process.argv.at(-1) + "\\n")
const responses = JSON.parse(fs.readFileSync(process.env.FAKE_RESPONSES, "utf8"))
const index = Number(fs.existsSync(process.env.FAKE_COUNT) ? fs.readFileSync(process.env.FAKE_COUNT, "utf8") : 0)
fs.writeFileSync(process.env.FAKE_COUNT, String(index + 1))
const response = responses[Math.min(index, responses.length - 1)]
if (response === null) process.exit(1)
process.stdout.write(JSON.stringify(response))
`

function runPair(t, args, responses) {
  const dir = mkdtempSync(join(tmpdir(), "tier2-pair-"))
  t.after(() => rmSync(dir, { recursive: true, force: true }))
  for (const [name, body] of [
    ["curl", fakeCurl],
    ["sleep", '#!/bin/sh\necho "$1" >> "$FAKE_SLEEPS"\n']
  ]) {
    writeFileSync(join(dir, name), body)
    chmodSync(join(dir, name), 0o755)
  }
  writeFileSync(join(dir, "responses.json"), JSON.stringify(responses))
  for (const name of ["output", "calls", "sleeps"]) writeFileSync(join(dir, name), "")
  const result = spawnSync("bash", [script, ...args], {
    encoding: "utf8",
    env: {
      PATH: `${dir}:${process.env.PATH}`,
      GITHUB_REPOSITORY: "851-labs/codevisor",
      GH_TOKEN: "token",
      GITHUB_RUN_ID: "500",
      GITHUB_RUN_ATTEMPT: "1",
      GITHUB_JOB: "host",
      RUNNER_NAME: "tamales-Mac-Mini-tamale",
      GITHUB_OUTPUT: join(dir, "output"),
      TIER2_PAIR_POLL_S: "15",
      TIER2_PAIR_CONFIRM_S: "30",
      FAKE_RESPONSES: join(dir, "responses.json"),
      FAKE_COUNT: join(dir, "count"),
      FAKE_CALLS: join(dir, "calls"),
      FAKE_SLEEPS: join(dir, "sleeps")
    }
  })
  const lines = (name) => readFileSync(join(dir, name), "utf8").split("\n").filter(Boolean)
  return { ...result, output: lines("output"), calls: lines("calls"), sleeps: lines("sleeps") }
}

const jobs = (...list) => ({ jobs: list })
const job = (name, status, extra = {}) => ({ name, status, ...extra })
const host = job("host", "in_progress", { id: 1, runner_name: "tamales-Mac-Mini-tamale" })
const viewer = (status, extra = {}) => job("viewer", status, { id: 2, ...extra })
const peer = (...statuses) => statuses.map((status) => jobs(host, viewer(status)))

test("pairs once the peer has been running for the confirm interval", (t) => {
  const result = runPair(t, ["viewer", "600", "yield"], peer("queued", "in_progress"))
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(result.output, ["paired=true"])
  assert.equal(result.calls.length, 4)
  assert.deepEqual(result.sleeps, ["15", "15", "15"])
})

test("pairs only with the peer of its own workflow_call caller", (t) => {
  const result = runPair(
    t,
    ["viewer", "600", "yield"],
    [
      jobs(
        job("calibration / host", "completed", {
          id: 7,
          conclusion: "success",
          runner_name: "tamales-Mac-Mini-tamale"
        }),
        job("calibration / viewer", "completed", { id: 8, conclusion: "success" }),
        job("tier2 / host", "in_progress", { id: 1, runner_name: "tamales-Mac-Mini-tamale" }),
        job("tier2 / viewer", "in_progress", { id: 2 })
      )
    ]
  )
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(result.output, ["paired=true"])
  assert.equal(result.calls.length, 3)
})

test("gives up the runner when the peer is still queued at the hold limit", (t) => {
  const result = runPair(t, ["viewer", "60", "yield"], peer("queued"))
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(result.output, ["paired=false"])
  assert.deepEqual(result.sleeps, ["15", "15", "15", "15"])
  assert.match(result.stderr, /still queued after 60s/)
})

test("pairs with the peer's retry, confirming it afresh, when the peer gave up its runner", (t) => {
  const yielded = viewer("completed", { conclusion: "success" })
  const result = runPair(
    t,
    ["viewer", "600", "yield"],
    [
      jobs(host, viewer("in_progress")),
      jobs(host, viewer("in_progress")),
      jobs(host, yielded),
      jobs(host, yielded, job("viewer-retry", "queued", { id: 3 })),
      jobs(host, yielded, job("viewer-retry", "in_progress", { id: 3 }))
    ]
  )
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(result.output, ["paired=true"])
  assert.equal(result.calls.length, 7)
})

test("fails at once when the peer can no longer run the bench", async (t) => {
  for (const ended of [
    [viewer("completed", { conclusion: "failure" })],
    [
      viewer("completed", { conclusion: "success" }),
      job("viewer-retry", "completed", { id: 3, conclusion: "skipped" })
    ],
    [
      viewer("completed", { conclusion: "success" }),
      job("viewer-retry", "completed", { id: 3, conclusion: "failure" })
    ]
  ]) {
    await t.test(ended.map((j) => `${j.name} ${j.conclusion}`).join(", "), (subtest) => {
      const result = runPair(subtest, ["viewer", "600", "yield"], [jobs(host, ...ended)])
      assert.equal(result.status, 1)
      assert.deepEqual(result.output, [])
      assert.equal(result.calls.length, 1)
    })
  }
})

test("the last attempt fails instead of giving up the runner", (t) => {
  const result = runPair(t, ["viewer", "30", "fail"], peer("queued"))
  assert.equal(result.status, 1)
  assert.deepEqual(result.output, [])
})

test("a failed API call at the hold limit doesn't give up the runner", (t) => {
  const result = runPair(
    t,
    ["viewer", "15", "yield"],
    [jobs(host, viewer("queued")), null, ...peer("in_progress")]
  )
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(result.output, ["paired=true"])
})

test("fails once the API stays unreadable well past the hold", (t) => {
  const result = runPair(t, ["viewer", "30", "yield"], [null])
  assert.equal(result.status, 1)
  assert.deepEqual(result.output, [])
  assert.deepEqual(result.sleeps, ["15", "15", "15", "15"])
})
