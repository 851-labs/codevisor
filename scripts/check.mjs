#!/usr/bin/env node
import { execFileSync, spawn } from "node:child_process"
import { createHash } from "node:crypto"
import {
  createWriteStream,
  existsSync,
  lstatSync,
  readFileSync,
  readdirSync,
  realpathSync
} from "node:fs"
import { mkdir, readFile, writeFile } from "node:fs/promises"
import { dirname, join, relative, resolve } from "node:path"
import { fileURLToPath } from "node:url"

import { developmentLayout } from "../packages/devtools/src/dev-layout.ts"
import { byCodeUnit, planChecks, relativeImports } from "./check-plan.mjs"
import { checkReporter } from "./check-report.mjs"

const repoRoot = fileURLToPath(new URL("..", import.meta.url))
const logDirectory = join(developmentLayout(repoRoot).build.root, "check")
const statePath = join(logDirectory, "passed.json")

const git = (...args) =>
  execFileSync("git", args, { cwd: repoRoot, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 })

function parseCheckArguments(argv) {
  const options = { all: false, base: "HEAD", dryRun: false, list: false, lanes: undefined }
  for (const argument of argv) {
    if (argument === "--all") options.all = true
    else if (argument === "--dry-run") options.dryRun = true
    else if (argument === "--list") options.list = true
    else if (argument.startsWith("--base=")) options.base = argument.slice("--base=".length)
    else if (argument.startsWith("--lanes="))
      options.lanes = argument.slice("--lanes=".length).split(",")
    else {
      throw new Error(
        `usage: check.mjs [--all] [--base=<ref>] [--lanes=<lane,…>] [--dry-run | --list] (unknown argument ${argument})`
      )
    }
  }
  return options
}

function inSelectedLanes(entry, lanes) {
  if (lanes === undefined || lanes.includes(entry.step.lane)) return entry
  return { ...entry, run: false, reason: "other lane" }
}

const splitPaths = (output) => output.split("\0").filter(Boolean)

function changedFiles(base) {
  return [
    ...new Set([
      ...splitPaths(git("diff", "--name-only", "--no-renames", "-z", base)),
      ...splitPaths(git("ls-files", "--others", "--exclude-standard", "-z"))
    ])
  ].toSorted(byCodeUnit)
}

function importClosure(entries) {
  const seen = new Set()
  const pending = [...entries]
  while (pending.length > 0) {
    const path = pending.pop()
    if (seen.has(path) || !existsSync(join(repoRoot, path))) continue
    seen.add(path)
    for (const specifier of relativeImports(readFileSync(join(repoRoot, path), "utf8"))) {
      pending.push(relative(repoRoot, resolve(repoRoot, dirname(path), specifier)))
    }
  }
  return [...seen]
}

function gatherContext() {
  const workspaces = ["apps", "packages", "plugins"].flatMap((parent) =>
    readdirSync(join(repoRoot, parent))
      .map((name) => `${parent}/${name}`)
      .filter((directory) => existsSync(join(repoRoot, directory, "package.json")))
      .map((directory) => ({
        directory,
        name: JSON.parse(readFileSync(join(repoRoot, directory, "package.json"), "utf8")).name
      }))
  )
  const releaseScripts = readdirSync(join(repoRoot, "scripts/release"))
    .filter((name) => name.endsWith(".mjs"))
    .map((name) => `scripts/release/${name}`)
  return {
    workspaces,
    scriptInputs: {
      "scripts/test-swift.mjs": importClosure(["scripts/test-swift.mjs"]),
      "scripts/release": importClosure(releaseScripts)
    },
    swiftLinks: swiftPackageLinks()
  }
}

function swiftPackageLinks() {
  const root = realpathSync(repoRoot)
  const links = []
  const walk = (directory) => {
    for (const entry of readdirSync(join(repoRoot, directory), { withFileTypes: true })) {
      const path = `${directory}/${entry.name}`
      if (entry.isSymbolicLink()) {
        links.push({ link: path, target: relative(root, realpathSync(join(repoRoot, path))) })
      } else if (
        entry.isDirectory() &&
        !entry.name.startsWith(".") &&
        entry.name !== "Frameworks"
      ) {
        walk(path)
      }
    }
  }
  walk("packages/swift")
  return links
}

function fileState(stat) {
  if (stat === undefined) return "deleted"
  return stat.isFile() ? undefined : "not a file"
}

function fingerprint(entry, baseCommit) {
  const contents = new Map(
    entry.inputs.map((path) => {
      const stat = lstatSync(join(repoRoot, path), { throwIfNoEntry: false })
      return [path, fileState(stat)]
    })
  )
  const files = [...contents].filter(([, content]) => content === undefined).map(([path]) => path)
  if (files.length > 0) {
    const hashes = execFileSync("git", ["hash-object", "--stdin-paths"], {
      cwd: repoRoot,
      encoding: "utf8",
      input: files.join("\n")
    }).split("\n")
    files.forEach((path, index) => contents.set(path, hashes[index]))
  }
  return createHash("sha256")
    .update(JSON.stringify([entry.step.command(entry.args), baseCommit, [...contents]]))
    .digest("hex")
}

const running = new Set()

function stepStatus(code, signal) {
  if (code === 0) return "passed"
  return signal === "SIGTERM" ? "cancelled" : "failed"
}

function runStep(entry, reporter) {
  const [command, ...args] = entry.step.command(entry.args)
  const log = join(logDirectory, `${entry.step.name.replaceAll(/[^\w.-]+/g, "_")}.log`)
  const output = createWriteStream(log)
  const startedAt = performance.now()
  reporter.started(entry)
  return new Promise((resolveStep) => {
    const child = spawn(command, args, {
      cwd: repoRoot,
      detached: true,
      stdio: ["ignore", "pipe", "pipe"]
    })
    running.add(child)
    for (const stream of [child.stdout, child.stderr]) {
      stream.pipe(output, { end: false })
      if (reporter.streamsOutput) stream.pipe(process.stdout, { end: false })
    }
    child.once("error", (error) => output.write(`${error.message}\n`))
    child.once("close", (code, signal) => {
      running.delete(child)
      output.end(() =>
        resolveStep({
          ...entry,
          log,
          seconds: (performance.now() - startedAt) / 1000,
          status: stepStatus(code, signal)
        })
      )
    })
  })
}

function stopRunning() {
  for (const child of running) {
    try {
      process.kill(-child.pid, "SIGTERM")
    } catch {}
  }
}

async function runLane(entries, results, state, reporter) {
  for (const entry of entries) {
    if (state.failed) {
      results.push({ ...entry, status: "cancelled" })
      continue
    }
    const finished = await runStep(entry, reporter)
    const result =
      finished.status !== "passed" && state.failed ? { ...finished, status: "cancelled" } : finished
    results.push(result)
    if (result.status === "passed") reporter.passed(result)
    else if (result.status === "failed") {
      state.failed = true
      stopRunning()
      reporter.failed(result)
    }
  }
}

function laneGroups(pending) {
  return [...new Set(pending.map((entry) => entry.step.lane))].map((lane) =>
    pending.filter((entry) => entry.step.lane === lane)
  )
}

async function runLanes(lanes, results, state, reporter) {
  if (reporter.runsLanesInParallel) {
    await Promise.all(lanes.map((lane) => runLane(lane, results, state, reporter)))
    return
  }

  for (const lane of lanes) await runLane(lane, results, state, reporter)
}

async function readPassedState() {
  if (!existsSync(statePath)) return {}
  return JSON.parse(await readFile(statePath, "utf8"))
}

async function main() {
  const startedAt = performance.now()
  const options = parseCheckArguments(process.argv.slice(2))
  const baseCommit = git("merge-base", options.base, "HEAD").trim()
  const files = changedFiles(baseCommit)
  const plan = planChecks({ files, all: options.all, context: gatherContext() }).map((entry) =>
    inSelectedLanes(entry, options.lanes)
  )
  await mkdir(logDirectory, { recursive: true })
  const passed = await readPassedState()
  const results = []
  const pending = []
  for (const entry of plan) {
    if (!entry.run) {
      results.push({ ...entry, status: "skipped" })
      continue
    }
    const key = entry.step.always ? undefined : fingerprint(entry, baseCommit)
    if (!options.all && key !== undefined && passed[entry.step.name] === key) {
      results.push({ ...entry, status: "skipped", reason: "passed on these inputs before" })
    } else pending.push({ ...entry, key })
  }
  if (options.list) {
    for (const entry of pending) console.log(entry.step.name)
    return
  }

  const base = options.base === "HEAD" ? "HEAD" : `${options.base} (${baseCommit.slice(0, 9)})`
  console.log(`${files.length} changed file(s) against ${base}`)
  if (options.dryRun) {
    for (const entry of pending) {
      console.log(`  run  ${entry.step.command(entry.args).join(" ")}  (${entry.reason})`)
    }
    for (const result of results) console.log(`  skip ${result.step.name}  (${result.reason})`)
    return
  }
  const state = { failed: false }
  for (const [signal, code] of [
    ["SIGINT", 130],
    ["SIGTERM", 143]
  ]) {
    process.once(signal, () => {
      stopRunning()
      process.exit(code)
    })
  }
  const reporter = checkReporter()
  await runLanes(laneGroups(pending), results, state, reporter)
  for (const result of results) {
    if (
      result.status === "passed" &&
      result.key !== undefined &&
      result.key === fingerprint(result, baseCommit)
    ) {
      passed[result.step.name] = result.key
    }
  }
  await writeFile(statePath, `${JSON.stringify(passed, null, 2)}\n`)
  reporter.finished(results, plan, (performance.now() - startedAt) / 1000)
  process.exitCode = state.failed ? 1 : 0
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await main()
}
