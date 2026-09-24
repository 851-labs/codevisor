#!/usr/bin/env node
// `bun run vnc:validate --issue 851-XXXX`: the one gate every VNC change
// passes (docs/plans/vnc-validation.md). Runs, in order and whatever fails:
//   tests   L1/L2 — the VNC Swift suites and the rig package's tests
//   interop L3    — `bun run vnc:interop` (pinned TigerVNC container)
//   bench         — `bun run vnc:bench` against this machine's baseline
//   tophat  L4    — `bun run vnc:tophat` (background, window-only)
// and writes docs/measurements/vnc/<date>-<issue>/report.md. Exit 0 only if
// every layer that ran passed. `--skip LAYER[,LAYER]` is for layers a change
// can't affect; say why in the commit.
import { spawn, spawnSync } from "node:child_process"
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

import {
  benchFailure,
  lastLine,
  layers,
  parseValidateArguments,
  renderReport,
  reportDirectory,
  testCount
} from "./vnc-validate-lib.mjs"

const root = dirname(dirname(dirname(dirname(fileURLToPath(import.meta.url)))))
// Same isolation as `bun run swift:test` (scripts/test-swift.mjs): suites that install a global
// executor hook run in their own process.
const mainSerialExecutorFilter = `(${JSON.parse(
  readFileSync(join(root, "packages/swift/main-serial-executor-suites.json"), "utf8")
).join("|")})/`
const usage = `Usage: bun run vnc:validate --issue 851-XXXX [--skip tests,interop,bench,tophat]
                           [--swift-filter REGEX] [--bench "--scenes typing --profiles wan150"]
                           [--machines loopback,contabo] [--save-baseline]

Runs ${layers.join(", ")} and writes docs/measurements/vnc/<date>-<issue>/report.md.
--save-baseline replaces this machine's vnc-bench baseline with this run (only when the issue
improves a metric, in the same commit).
`

let options
try {
  options = parseValidateArguments(process.argv.slice(2))
} catch (error) {
  process.stderr.write(`${error.message}\n\n${usage}`)
  process.exit(2)
}
if (options.help) {
  process.stdout.write(usage)
  process.exit(0)
}

/// Runs a command with its output streamed and captured.
function stream(command, args) {
  return new Promise((resolve) => {
    const started = Date.now()
    const child = spawn(command, args, { cwd: root, stdio: ["ignore", "pipe", "pipe"] })
    let output = ""
    for (const source of [child.stdout, child.stderr]) {
      source.on("data", (chunk) => {
        output += chunk
        process.stdout.write(chunk)
      })
    }
    child.on("close", (status) =>
      resolve({ status, output, seconds: (Date.now() - started) / 1000 })
    )
  })
}

const results = []
async function layer(name, work) {
  if (options.skip.has(name)) {
    results.push({ layer: name, skipped: true, summary: "skipped (--skip)" })
    return
  }
  process.stdout.write(`\n=== vnc:validate: ${name} ===\n`)
  results.push({ layer: name, ...(await work()) })
}

await layer("tests", async () => {
  const swift = await stream("swift", [
    "test",
    "--package-path",
    "packages/swift",
    "--filter",
    options.swiftFilter,
    "--skip",
    mainSerialExecutorFilter
  ])
  const rig = await stream("swift", ["test", "--package-path", "apps/screen-sharing-rig"])
  const counted = [swift, rig].map((run) => testCount(run.output))
  return {
    ok:
      swift.status === 0 &&
      rig.status === 0 &&
      counted.every((count) => count.ran > 0 && count.passed),
    seconds: swift.seconds + rig.seconds,
    summary: `packages/swift (${options.swiftFilter}): ${counted[0].ran} tests; rig package: ${counted[1].ran} tests`
  }
})

await layer("interop", async () => {
  const run = await stream("bun", ["run", "vnc:interop"])
  return {
    ok: run.status === 0,
    seconds: run.seconds,
    summary: lastLine(run.output, /^vnc:interop:/)
  }
})

await layer("bench", async () => {
  const run = await stream("bun", [
    "run",
    "vnc:bench",
    "--against-main",
    ...options.benchArgs,
    ...(options.saveBaseline ? ["--save-baseline"] : [])
  ])
  const reportPath = lastLine(run.output, /^Report: /).replace(/^Report: /, "")
  const directory = reportPath ? dirname(reportPath) : ""
  const read = (name) =>
    directory && existsSync(join(directory, name))
      ? readFileSync(join(directory, name), "utf8")
      : ""
  const comparison = read("comparison.md")
  const bench = read("bench.md")
  // Why a failed run stopped (851-2337): this build's run, or origin/main's.
  const failure = benchFailure(read("bench-error.txt"), read(join("main", "bench-error.txt")))
  return {
    ok: run.status === 0,
    seconds: run.seconds,
    summary:
      lastLine(run.output, /^vnc-bench: /) ||
      (run.status === 0 ? "no baseline to compare" : "failed"),
    detail: [failure, bench.replace(/^# vnc-bench\n/, ""), comparison].filter(Boolean).join("\n")
  }
})

await layer("tophat", async () => {
  const run = await stream("bun", ["run", "vnc:tophat", "--machines", options.machines])
  const failures = run.output
    .split("\n")
    .filter((line) => line.startsWith("✘"))
    .join("\n")
  return {
    ok: run.status === 0,
    seconds: run.seconds,
    summary: lastLine(run.output, /^vnc:tophat:/).replace(/ Summary and screenshots:.*/, ""),
    detail: failures ? `Failed steps:\n\n${failures}` : ""
  }
})

const hash = spawnSync("git", ["rev-parse", "--short=12", "HEAD"], {
  cwd: root,
  encoding: "utf8"
}).stdout.trim()
const dirty =
  spawnSync("git", ["status", "--porcelain"], { cwd: root, encoding: "utf8" }).stdout.trim() !== ""
const machine = spawnSync("sysctl", ["-n", "hw.model"], { encoding: "utf8" }).stdout.trim()
const report = renderReport({
  issue: options.issue,
  build: `${hash}${dirty ? "+dirty" : ""}`,
  machine,
  results
})
const directory = join(root, reportDirectory(new Date(), options.issue))
mkdirSync(directory, { recursive: true })
writeFileSync(join(directory, "validate.md"), report.text)
process.stdout.write(`\n${report.text}\nWritten to ${join(directory, "validate.md")}\n`)
process.exit(report.ok ? 0 : 1)
