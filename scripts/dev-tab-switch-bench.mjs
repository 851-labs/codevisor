#!/usr/bin/env node

import { execFileSync } from "node:child_process"
import { readFile } from "node:fs/promises"
import { join } from "node:path"
import { setTimeout as sleep } from "node:timers/promises"
import { pathToFileURL } from "node:url"

import { summarizeTranscriptPerformance } from "./transcript-performance-summary.mjs"

const usage =
  "Usage: TRANSCRIPT_STRESS_URL=<dev server URL> node scripts/dev-tab-switch-bench.mjs [--chats <n>] [--turns <n>] [--warm-rounds <n>] [--trace <path>]"
const keptAlivePages = 5
const switchRecordName = "navigation.switch"
const recordPollMilliseconds = 50
const recordTimeoutMilliseconds = 10_000
const pauseBetweenSwitchesMilliseconds = 400
const pauseAfterSeedingMilliseconds = 3_000

export function benchPlan(workspaceIds, warmRounds, keptAlive = keptAlivePages) {
  const firstVisits = workspaceIds.map((workspaceId) => ({ scenario: "first-visit", workspaceId }))
  const evicted = workspaceIds
    .slice(0, Math.max(0, workspaceIds.length - keptAlive))
    .map((workspaceId) => ({ scenario: "evicted-reopen", workspaceId }))
  const shown = [...firstVisits, ...evicted].map((step) => step.workspaceId)
  const warmPair = [shown.at(-2), shown.at(-1)]
  const warm = Array.from({ length: warmRounds * 2 }, (_, index) => ({
    scenario: "warm",
    workspaceId: warmPair[index % 2]
  }))
  return [...firstVisits, ...evicted, ...warm]
}

export function summarizeSwitches(switches) {
  const timings = switches.flatMap(({ scenario, record }) => [
    { name: `${scenario}.busy`, durationMS: record.durationMS },
    { name: `${scenario}.firstPass`, durationMS: record.values?.firstPassMS },
    { name: `${scenario}.settle`, durationMS: record.values?.settleMS }
  ])
  return summarizeTranscriptPerformance(timings).timings
}

async function main(argv) {
  const options = parseOptions(argv)
  const server = serverUrl()
  const clientId = await macClientId(server)
  const workspaceIds = await seedChats(server, options)

  const switches = []
  for (const step of benchPlan(workspaceIds, options.warmRounds)) {
    const record = await timedSwitch(server, clientId, options.trace, step.workspaceId)
    switches.push({ scenario: step.scenario, record })
    await sleep(pauseBetweenSwitchesMilliseconds)
  }

  process.stdout.write(`${JSON.stringify(summarizeSwitches(switches), null, 2)}\n`)
}

function parseOptions(argv) {
  const options = {
    chats: 8,
    turns: 200,
    warmRounds: 10,
    trace: join(appTemporaryDirectory(), "codevisor-transcript-performance.jsonl")
  }
  const names = { "--chats": "chats", "--turns": "turns", "--warm-rounds": "warmRounds" }
  for (let index = 0; index < argv.length; index += 2) {
    const [flag, value] = [argv[index], argv[index + 1]]
    if (value === undefined) throw new Error(usage)
    if (flag === "--trace") options.trace = value
    else if (flag in names) options[names[flag]] = positiveInteger(flag, value)
    else throw new Error(usage)
  }
  if (options.chats < 2) throw new Error("--chats must be at least 2")
  return options
}

function appTemporaryDirectory() {
  return execFileSync("getconf", ["DARWIN_USER_TEMP_DIR"], { encoding: "utf8" }).trim()
}

function positiveInteger(flag, value) {
  const number = Number(value)
  if (!Number.isInteger(number) || number < 1) throw new Error(`${flag} needs a positive integer`)
  return number
}

function serverUrl() {
  const url = process.env.TRANSCRIPT_STRESS_URL
  if (!url) throw new Error(usage)
  return url
}

async function macClientId(server) {
  const clients = await requestJson(server, "GET", "/v1/clients")
  const client = clients.find((candidate) => candidate.platform === "macos")
  if (client === undefined)
    throw new Error(
      "No macOS app is connected to this server; start it with TRANSCRIPT_STRESS=1 bun run dev:macos"
    )
  return client.clientId
}

async function seedChats(server, options) {
  const workspaceIds = []
  for (let index = 1; index <= options.chats; index += 1) {
    const seeded = await stress(server, {
      action: "seed",
      title: `Tab switch bench ${index}`,
      folderPath: process.cwd(),
      turns: options.turns
    })
    await stress(server, { action: "chunk", sessionId: seeded.sessionId, text: "Done." })
    await stress(server, { action: "finish", sessionId: seeded.sessionId })
    workspaceIds.push(seeded.workspaceId)
  }
  await sleep(pauseAfterSeedingMilliseconds)
  return workspaceIds
}

function stress(server, body) {
  return requestJson(server, "POST", "/dev/transcript-stress", body)
}

async function timedSwitch(server, clientId, trace, workspaceId) {
  const before = (await switchRecords(trace)).length
  await requestJson(server, "POST", `/v1/clients/${clientId}/navigate`, { workspaceId })

  const deadline = Date.now() + recordTimeoutMilliseconds
  while (Date.now() < deadline) {
    const records = await switchRecords(trace)
    if (records.length > before) return records.at(-1)
    await sleep(recordPollMilliseconds)
  }
  throw new Error(
    `The app recorded no switch to workspace ${workspaceId} in ${trace}; is it a Debug build started with TRANSCRIPT_STRESS=1?`
  )
}

async function switchRecords(trace) {
  const source = await readFile(trace, "utf8").catch(() => "")
  return source
    .split("\n")
    .map(parsedRecord)
    .filter((record) => record?.name === switchRecordName)
}

function parsedRecord(line) {
  try {
    return JSON.parse(line)
  } catch {
    return undefined
  }
}

async function requestJson(server, method, path, body) {
  const response = await fetch(new URL(path, server), {
    method,
    ...(body === undefined
      ? {}
      : { headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) })
  })
  const text = await response.text()
  if (!response.ok) throw new Error(`${method} ${path} answered ${response.status}: ${text}`)
  return JSON.parse(text)
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href)
  await main(process.argv.slice(2))
