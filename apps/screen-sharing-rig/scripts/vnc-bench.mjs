#!/usr/bin/env node
// `bun run vnc:bench`: the VNC benchmark of docs/plans/vnc-validation.md.
// Builds the rig in release mode, runs `screen-sharing-rig vnc-bench` with
// the build's hash, writes the report under tmp/vnc-bench/<time>/, and
// compares with docs/measurements/vnc/baseline-<machine>.json when present
// (exit 1 on a regression beyond the noise band). --save-baseline makes this
// run the machine's baseline.
import { spawnSync } from "node:child_process"
import { copyFileSync, existsSync, mkdirSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

import {
  baselineName,
  buildLabel,
  parseBenchArguments,
  runDirectoryName
} from "./vnc-bench-lib.mjs"

const root = dirname(dirname(dirname(dirname(fileURLToPath(import.meta.url)))))
const packagePath = join(root, "apps/screen-sharing-rig")
const usage = `Usage: bun run vnc:bench [vnc-bench options] [--save-baseline] [--no-compare] [--against-main]

--against-main builds origin/main in tmp/vnc-bench/main-worktree and benchmarks it first, in the
same session, then compares this build with it (A/B) instead of the stored baseline.

Options passed through: --scenes, --profiles, --runs, --frames, --size, --seed
(see \`screen-sharing-rig vnc-bench --help\`). Run on AC power with nothing else heavy running.
`

let options
try {
  options = parseBenchArguments(process.argv.slice(2))
} catch (error) {
  process.stderr.write(`${error.message}\n\n${usage}`)
  process.exit(2)
}
if (options.help) {
  process.stdout.write(usage)
  process.exit(0)
}

const run = (command, args, extra = {}) => {
  const result = spawnSync(command, args, { encoding: "utf8", ...extra })
  if (result.status !== 0 && !extra.allowFailure) {
    throw new Error(`${command} ${args.join(" ")} failed:\n${result.stderr || result.stdout}`)
  }
  return result
}

process.stdout.write("Building the rig (release)…\n")
run(
  "swift",
  ["build", "-c", "release", "--package-path", packagePath, "--product", "screen-sharing-rig"],
  {
    stdio: ["ignore", "ignore", "inherit"]
  }
)
const binary = join(
  run("swift", [
    "build",
    "-c",
    "release",
    "--package-path",
    packagePath,
    "--show-bin-path"
  ]).stdout.trim(),
  "screen-sharing-rig"
)
const hash = run("git", ["-C", root, "rev-parse", "HEAD"]).stdout
const dirty = run("git", ["-C", root, "status", "--porcelain"]).stdout.trim().length > 0
const model = run("sysctl", ["-n", "hw.model"]).stdout
const baseline = join(root, "docs/measurements/vnc", baselineName(model))
const output = join(root, "tmp/vnc-bench", runDirectoryName(new Date()))
mkdirSync(output, { recursive: true })

const args = [
  "vnc-bench",
  ...options.passThrough,
  "--out",
  output,
  "--build",
  buildLabel(hash, dirty)
]
if (options.compare && existsSync(baseline)) args.push("--baseline", baseline)
if (options.againstMain) {
  // A/B in one session: the stored baseline can drift with the machine's state
  // (CPU figures moved 0.57 → 1.45 ms between sessions on an unchanged build,
  // 851-2314), so measure origin/main now, under the same conditions, and
  // compare with that. The stored baseline stays the historical record.
  const worktree = join(root, "tmp/vnc-bench/main-worktree")
  run("git", ["-C", root, "fetch", "-q", "origin", "main"])
  if (existsSync(join(worktree, ".git"))) {
    run("git", ["-C", worktree, "checkout", "-q", "--detach", "origin/main"])
  } else {
    run("git", ["-C", root, "worktree", "add", "-q", "--detach", worktree, "origin/main"])
  }
  const mainHash = run("git", ["-C", worktree, "rev-parse", "HEAD"]).stdout
  process.stdout.write(
    `Building origin/main (${buildLabel(mainHash, false)}) for the A/B comparison…\n`
  )
  const mainPackage = join(worktree, "apps/screen-sharing-rig")
  run(
    "swift",
    ["build", "-c", "release", "--package-path", mainPackage, "--product", "screen-sharing-rig"],
    {
      stdio: ["ignore", "ignore", "inherit"]
    }
  )
  const mainBinary = join(
    run("swift", [
      "build",
      "-c",
      "release",
      "--package-path",
      mainPackage,
      "--show-bin-path"
    ]).stdout.trim(),
    "screen-sharing-rig"
  )
  const mainOutput = join(output, "main")
  const reference = spawnSync(
    mainBinary,
    [
      "vnc-bench",
      ...options.passThrough,
      "--out",
      mainOutput,
      "--build",
      `main ${buildLabel(mainHash, false)}`
    ],
    { stdio: "inherit" }
  )
  if (reference.status !== 0) {
    process.stderr.write("vnc:bench: the origin/main run failed; no A/B comparison\n")
    // Still name the directory: its main/bench-error.txt says why (851-2337).
    process.stdout.write(`\nReport: ${join(output, "bench.md")}\n`)
    process.exit(1)
  }
  const index = args.indexOf("--baseline")
  if (index >= 0) args.splice(index, 2)
  args.push("--baseline", join(mainOutput, "bench.json"))
}
const bench = spawnSync(binary, args, { stdio: "inherit" })
process.stdout.write(`\nReport: ${join(output, "bench.md")}\n`)
if (options.saveBaseline && bench.status === 0) {
  mkdirSync(dirname(baseline), { recursive: true })
  copyFileSync(join(output, "bench.json"), baseline)
  process.stdout.write(`Saved as the baseline: ${baseline}\n`)
}
process.exit(bench.status ?? 1)
