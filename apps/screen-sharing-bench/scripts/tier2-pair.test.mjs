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
      TIER2_MINIS_POLL_S: "60",
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
const peerRoute = (...statuses) => [
  {
    path: jobsPath,
    responses: statuses.map((status) => jobs(job("host", "in_progress"), job("viewer", status)))
  }
]

test("pairs once the peer has been running for the confirm interval", (t) => {
  const result = runPair(t, ["pair", "viewer", "300", "yield"], peerRoute("queued", "in_progress"))
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(result.output, ["paired=true"])
  assert.equal(result.calls.length, 4)
  assert.deepEqual(result.sleeps, ["15", "15", "15"])
})

test("finds the peer under the job names a workflow_call caller gives", (t) => {
  const result = runPair(
    t,
    ["pair", "viewer", "300", "yield"],
    [
      {
        path: jobsPath,
        responses: [jobs(job("tier2 / host", "in_progress"), job("tier2 / viewer", "in_progress"))]
      }
    ]
  )
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(result.output, ["paired=true"])
})

test("releases the runner when the peer is still queued at the hold limit", (t) => {
  const result = runPair(t, ["pair", "viewer", "60", "yield"], peerRoute("queued"))
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(result.output, ["paired=false"])
  assert.deepEqual(result.sleeps, ["15", "15", "15", "15"])
  assert.match(result.stderr, /still queued after 60s/)
})

test("never pairs with a peer that finished while being confirmed", (t) => {
  const result = runPair(
    t,
    ["pair", "viewer", "300", "yield"],
    peerRoute("in_progress", "in_progress", "completed")
  )
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(result.output, ["paired=false"])
})

test("the last attempt fails instead of releasing the runner", (t) => {
  const result = runPair(t, ["pair", "viewer", "30", "fail"], peerRoute("queued"))
  assert.equal(result.status, 1)
  assert.deepEqual(result.output, [])
})

test("an API failure counts as an unstarted peer", (t) => {
  const result = runPair(
    t,
    ["pair", "viewer", "15", "yield"],
    [{ path: jobsPath, responses: [null] }]
  )
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(result.output, ["paired=false"])
})

const runsRoute = (status, ...ids) => ({
  path: `actions/runs?status=${status}`,
  responses: [{ workflow_runs: ids.map((id) => ({ id })) }]
})

test("waits for other runs' jobs on a mini, then starts", (t) => {
  const result = runPair(
    t,
    ["wait-for-minis", "3600"],
    [
      runsRoute("in_progress", runId, 7),
      runsRoute("queued", 8),
      {
        path: "actions/runs/7/jobs",
        responses: [
          jobs(
            job("macos", "in_progress", { runner_name: "croissants-Mac-Mini-croissant" }),
            job("lint", "in_progress", { runner_name: "GitHub Actions 12" })
          ),
          jobs(job("macos", "completed", { runner_name: "croissants-Mac-Mini-croissant" }))
        ]
      },
      {
        path: "actions/runs/8/jobs",
        responses: [
          jobs(job("ios", "queued", { labels: ["self-hosted", "macOS", "ARM64"] })),
          jobs(job("ios", "in_progress", { runner_name: "tamales-Mac-Mini-tamale" })),
          jobs(job("ios", "completed", { runner_name: "tamales-Mac-Mini-tamale" })),
          jobs(
            job("ubuntu", "queued", { labels: ["ubuntu-24.04"] }),
            job("gpu", "queued", { labels: ["self-hosted", "Linux", "gpu"] })
          )
        ]
      }
    ]
  )
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(result.sleeps, ["60", "60"])
  assert.ok(!result.calls.some((call) => call.includes(`runs/${runId}/`)))
  assert.match(result.stderr, /macos, in_progress on croissants-Mac-Mini-croissant/)
  assert.doesNotMatch(result.stderr, /lint/)
  assert.match(result.stderr, /tamale and croissant are free/)
})

test("starts anyway once the minis stay busy past the patience", (t) => {
  const result = runPair(
    t,
    ["wait-for-minis", "120"],
    [
      runsRoute("in_progress", 7),
      runsRoute("queued"),
      {
        path: "actions/runs/7/jobs",
        responses: [jobs(job("gate", "in_progress", { runner_name: "tamale" }))]
      }
    ]
  )
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(result.sleeps, ["60", "60"])
  assert.match(result.stderr, /still busy after 120s; starting anyway/)
})
