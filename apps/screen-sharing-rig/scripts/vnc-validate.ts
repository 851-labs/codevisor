#!/usr/bin/env node
import { spawn, spawnSync } from "node:child_process"
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

import { errorMessage } from "./screen-sharing-rig-lib.ts"
import {
  benchFailure,
  lastLine,
  type LayerResult,
  layers,
  parseValidateArguments,
  renderReport,
  reportDirectory,
  testCount,
  type ValidateOptions
} from "./vnc-validate-lib.ts"

const root = dirname(dirname(dirname(dirname(fileURLToPath(import.meta.url)))))
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

let options: ValidateOptions
try {
  options = parseValidateArguments(process.argv.slice(2))
} catch (error) {
  process.stderr.write(`${errorMessage(error)}\n\n${usage}`)
  process.exit(2)
}
if (options.help) {
  process.stdout.write(usage)
  process.exit(0)
}
const issue = options.issue ?? ""

interface StreamedRun {
  status: number | null
  output: string
  seconds: number
}

function stream(command: string, args: string[]): Promise<StreamedRun> {
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

const results: LayerResult[] = []
async function layer(name: string, work: () => Promise<Omit<LayerResult, "layer">>) {
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
  const swiftCount = testCount(swift.output)
  const rigCount = testCount(rig.output)
  return {
    ok:
      swift.status === 0 &&
      rig.status === 0 &&
      [swiftCount, rigCount].every((count) => count.ran > 0 && count.passed),
    seconds: swift.seconds + rig.seconds,
    summary: `packages/swift (${options.swiftFilter}): ${swiftCount.ran} tests; rig package: ${rigCount.ran} tests`
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
  const read = (name: string) =>
    directory && existsSync(join(directory, name))
      ? readFileSync(join(directory, name), "utf8")
      : ""
  const comparison = read("comparison.md")
  const bench = read("bench.md")
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
  issue,
  build: `${hash}${dirty ? "+dirty" : ""}`,
  machine,
  results
})
const directory = join(root, reportDirectory(new Date(), issue))
mkdirSync(directory, { recursive: true })
writeFileSync(join(directory, "validate.md"), report.text)
process.stdout.write(`\n${report.text}\nWritten to ${join(directory, "validate.md")}\n`)
process.exit(report.ok ? 0 : 1)
