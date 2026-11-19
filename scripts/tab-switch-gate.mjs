#!/usr/bin/env node

import { realpathSync } from "node:fs"
import { readFile, writeFile } from "node:fs/promises"
import { pathToFileURL } from "node:url"

const usage =
  "Usage: node scripts/tab-switch-gate.mjs judge --index <index.jsonl> --run <summary.json> [--run <summary.json>] --report <report.md> | record --index <index.jsonl> --run <summary.json> --id <run id> --sha <commit> --date <ISO date>"

export const method = "8-chats-200-turns-v1"
export const baselineNights = 7
export const minimumNights = 3
export const regressedExitCode = 3
const rules = {
  p50MS: { title: "Median", ratio: 0.15, floorMS: 3 },
  p95MS: { title: "95th percentile", ratio: 0.2, floorMS: 5 }
}

function median(values) {
  const sorted = values.toSorted((a, b) => a - b)
  const middle = Math.floor(sorted.length / 2)
  return sorted.length % 2 === 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
}

function busyScenarios(summary) {
  return Object.keys(summary)
    .filter((name) => name.endsWith(".busy"))
    .map((name) => name.slice(0, -".busy".length))
}

export function parseIndex(source) {
  return source
    .split("\n")
    .filter((line) => line.trim() !== "")
    .map((line) => JSON.parse(line))
}

export function baselineOf(entries) {
  const nights = entries
    .filter((entry) => entry.kind === "nightly" && entry.method === method)
    .slice(-baselineNights)
  const scenarios = {}
  for (const scenario of new Set(nights.flatMap((night) => busyScenarios(night.summary)))) {
    const measured = nights.map((night) => night.summary[`${scenario}.busy`]).filter(Boolean)
    scenarios[scenario] = {
      nights: measured.length,
      ...Object.fromEntries(
        Object.keys(rules).map((measure) => [
          measure,
          median(measured.map((busy) => busy[measure]))
        ])
      )
    }
  }
  return { nights: nights.length, scenarios }
}

export function allowed(baseline, measure) {
  const rule = rules[measure]
  return baseline + Math.max(baseline * rule.ratio, rule.floorMS)
}

function isJudged(baseline, scenario) {
  return (baseline.scenarios[scenario]?.nights ?? 0) >= minimumNights
}

function crosses(run, baseline, scenario, measure) {
  const measured = run[`${scenario}.busy`]?.[measure]
  return (
    measured === undefined || measured > allowed(baseline.scenarios[scenario][measure], measure)
  )
}

export function regressions(runs, baseline) {
  return Object.keys(baseline.scenarios)
    .filter((scenario) => isJudged(baseline, scenario))
    .flatMap((scenario) =>
      Object.keys(rules)
        .filter((measure) => runs.every((run) => crosses(run, baseline, scenario, measure)))
        .map((measure) => ({ scenario, measure }))
    )
}

function round(value) {
  return Math.round(value * 10) / 10
}

function reportRow(runs, baseline, failed, scenario, measure) {
  const measured = runs.map((run) => run[`${scenario}.busy`]?.[measure])
  const shown = measured.map((value) => (value === undefined ? "not measured" : round(value)))
  if (!isJudged(baseline, scenario))
    return `| ${scenario} | ${rules[measure].title} | ${shown.join(" / ")} |  |  | no baseline yet |`
  const base = baseline.scenarios[scenario][measure]
  const limit = allowed(base, measure)
  const result = resultOf(measured, limit, failed)
  return `| ${scenario} | ${rules[measure].title} | ${shown.join(" / ")} | ${round(base)} | ${round(limit)} | ${result} |`
}

function resultOf(measured, limit, failed) {
  if (measured.every((value) => value === undefined)) return "not measured"
  if (failed) return "over in every run"
  const isWithin = measured.every((value) => value !== undefined && value <= limit)
  return isWithin ? "within" : "over in one run, ignored"
}

export function gateReport(runs, baseline) {
  const failed = regressions(runs, baseline)
  const scenarios = [
    ...new Set([...runs.flatMap(busyScenarios), ...Object.keys(baseline.scenarios)])
  ]
  const rows = scenarios.flatMap((scenario) =>
    Object.keys(rules).map((measure) => {
      const isFailed = failed.some((item) => item.scenario === scenario && item.measure === measure)
      return reportRow(runs, baseline, isFailed, scenario, measure)
    })
  )
  const basis =
    baseline.nights < minimumNights
      ? `The baseline has ${baseline.nights} of the ${minimumNights} nightly runs it needs, so nothing is judged yet.`
      : `Judged against the median of the last ${baseline.nights} nightly runs that passed. A switch fails when every run is over the limit or it was not measured.`
  return [
    "| Switch | Measure | This run, ms | Baseline, ms | Limit, ms | Result |",
    "|---|---|---|---|---|---|",
    ...rows,
    "",
    basis,
    ""
  ].join("\n")
}

export function indexEntry(summary, { id, sha, date }) {
  return { run: id, sha, date, kind: "nightly", method, summary }
}

function options(argv) {
  const parsed = { runs: [] }
  for (let index = 0; index < argv.length; index += 2) {
    const [flag, value] = [argv[index], argv[index + 1]]
    if (!flag.startsWith("--") || value === undefined) throw new Error(usage)
    if (flag === "--run") parsed.runs.push(value)
    else parsed[flag.slice(2)] = value
  }
  return parsed
}

async function readJson(path) {
  return JSON.parse(await readFile(path, "utf8"))
}

async function judge(parsed) {
  if (parsed.index === undefined || parsed.report === undefined || parsed.runs.length === 0)
    throw new Error(usage)
  const runs = await Promise.all(parsed.runs.map(readJson))
  const baseline = baselineOf(parseIndex(await readFile(parsed.index, "utf8")))
  await writeFile(parsed.report, gateReport(runs, baseline))
  const failed = regressions(runs, baseline)
  for (const { scenario, measure } of failed)
    process.stderr.write(
      `${scenario}: ${rules[measure].title.toLowerCase()} is over its limit in every run\n`
    )
  if (failed.length > 0) process.exitCode = regressedExitCode
}

export function withEntry(source, entry) {
  if (parseIndex(source).some((existing) => existing.run === entry.run)) return source
  const lines = source === "" || source.endsWith("\n") ? source : `${source}\n`
  return `${lines}${JSON.stringify(entry)}\n`
}

async function readIndex(path) {
  try {
    return await readFile(path, "utf8")
  } catch (error) {
    if (error.code === "ENOENT") return ""
    throw error
  }
}

async function record(parsed) {
  const missing = ["index", "id", "sha", "date"].some((name) => parsed[name] === undefined)
  if (missing || parsed.runs.length !== 1) throw new Error(usage)
  const entry = indexEntry(await readJson(parsed.runs[0]), parsed)
  await writeFile(parsed.index, withEntry(await readIndex(parsed.index), entry))
}

async function main(argv) {
  const [action, ...rest] = argv
  if (action === "judge") await judge(options(rest))
  else if (action === "record") await record(options(rest))
  else throw new Error(usage)
}

if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href)
  await main(process.argv.slice(2))
