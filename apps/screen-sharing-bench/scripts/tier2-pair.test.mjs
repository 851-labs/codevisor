import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"
import { fileURLToPath } from "node:url"

const script = fileURLToPath(new URL("./tier2-pair.sh", import.meta.url))
const runId = 500
const jobsPath = `actions/runs/${runId}/attempts/1/jobs`

const fakeGh = `#!/usr/bin/env node
const fs = require("node:fs")
const path = process.argv[3]
fs.appendFileSync(process.env.FAKE_CALLS, path + "\\n")
const routes = JSON.parse(fs.readFileSync(process.env.FAKE_ROUTES, "utf8"))
const route = routes.find((candidate) => path.includes(candidate.path))
if (!route) process.exit(1)
const counts = fs.existsSync(process.env.FAKE_COUNTS) ? JSON.parse(fs.readFileSync(process.env.FAKE_COUNTS, "utf8")) : {}
const index = counts[route.path] ?? 0
counts[route.path] = index + 1
fs.writeFileSync(process.env.FAKE_COUNTS, JSON.stringify(counts))
const response = route.responses[Math.min(index, route.responses.length - 1)]
if (response === null) process.exit(1)
process.stdout.write(JSON.stringify(response))
`

function runPair(t, args, routes, env = {}) {
  const dir = mkdtempSync(join(tmpdir(), "tier2-pair-"))
  t.after(() => rmSync(dir, { recursive: true, force: true }))
  for (const [name, body] of [
    ["gh", fakeGh],
    ["sleep", '#!/bin/sh\necho "$1" >> "$FAKE_SLEEPS"\n']
  ]) {
    writeFileSync(join(dir, name), body)
    chmodSync(join(dir, name), 0o755)
  }
  writeFileSync(join(dir, "routes.json"), JSON.stringify(routes))
  writeFileSync(join(dir, "output"), "")
  writeFileSync(join(dir, "calls"), "")
  writeFileSync(join(dir, "sleeps"), "")
  const result = spawnSync("bash", [script, ...args], {
    encoding: "utf8",
    env: {
      PATH: `${dir}:${process.env.PATH}`,
      GITHUB_REPOSITORY: "851-labs/codevisor",
      GITHUB_RUN_ID: String(runId),
      GITHUB_RUN_ATTEMPT: "1",
      GITHUB_OUTPUT: join(dir, "output"),
      TIER2_PAIR_POLL_S: "15",
      TIER2_PAIR_CONFIRM_S: "30",
      FAKE_ROUTES: join(dir, "routes.json"),
      FAKE_COUNTS: join(dir, "counts.json"),
      FAKE_CALLS: join(dir, "calls"),
      FAKE_SLEEPS: join(dir, "sleeps"),
      ...env
    }
  })
  const lines = (name) => readFileSync(join(dir, name), "utf8").split("\n").filter(Boolean)
  return { ...result, output: lines("output"), calls: lines("calls"), sleeps: lines("sleeps") }
}

const jobs = (...list) => ({ jobs: list })
const job = (name, status, extra = {}) => ({
  name,
  status,
  html_url: `https://example.test/${name}`,
  ...extra
})
const host = job("host", "in_progress", { id: 1 })
const route = (...responses) => [{ path: jobsPath, responses }]
const peerRoute = (...statuses) =>
  route(...statuses.map((status) => jobs(host, job("viewer", status, { id: 2 }))))

test("pairs once the peer has been running for the confirm interval", (t) => {
  const result = runPair(t, ["pair", "viewer", "600", "yield"], peerRoute("queued", "in_progress"))
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(result.output, ["paired=true"])
  assert.equal(result.calls.length, 4)
  assert.deepEqual(result.sleeps, ["15", "15", "15"])
})

test("finds the peer under the job names a workflow_call caller gives", (t) => {
  const result = runPair(
    t,
    ["pair", "viewer", "600", "yield"],
    route(
      jobs(
        job("tier2 / host", "in_progress", { id: 1 }),
        job("tier2 / viewer", "in_progress", { id: 2 })
      )
    )
  )
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(result.output, ["paired=true"])
})

test("gives up the runner when the peer is still queued at the hold limit", (t) => {
  const result = runPair(t, ["pair", "viewer", "60", "yield"], peerRoute("queued"))
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(result.output, ["paired=false"])
  assert.deepEqual(result.sleeps, ["15", "15", "15", "15"])
  assert.match(result.stderr, /still queued after 60s/)
})

test("pairs with the peer's retry, confirming it afresh, when the peer gave up its runner", (t) => {
  const yielded = job("viewer", "completed", { id: 2, conclusion: "success" })
  const result = runPair(
    t,
    ["pair", "viewer", "600", "yield"],
    route(
      jobs(host, job("viewer", "in_progress", { id: 2 })),
      jobs(host, job("viewer", "in_progress", { id: 2 })),
      jobs(host, yielded),
      jobs(host, yielded, job("viewer-retry", "queued", { id: 3 })),
      jobs(host, yielded, job("viewer-retry", "in_progress", { id: 3 }))
    )
  )
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(result.output, ["paired=true"])
  assert.equal(result.calls.length, 7)
})

test("fails at once when the peer ended and its retry was skipped", (t) => {
  const result = runPair(
    t,
    ["pair", "viewer", "600", "yield"],
    route(
      jobs(
        host,
        job("viewer", "completed", { id: 2, conclusion: "failure" }),
        job("viewer-retry", "completed", { id: 3, conclusion: "skipped" })
      )
    )
  )
  assert.equal(result.status, 1)
  assert.deepEqual(result.output, [])
  assert.equal(result.calls.length, 1)
})

test("the last attempt fails instead of giving up the runner", (t) => {
  const result = runPair(t, ["pair", "viewer", "30", "fail"], peerRoute("queued"))
  assert.equal(result.status, 1)
  assert.deepEqual(result.output, [])
})

test("an API failure counts as an unstarted peer", (t) => {
  const result = runPair(t, ["pair", "viewer", "15", "yield"], route(null))
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(result.output, ["paired=false"])
})
