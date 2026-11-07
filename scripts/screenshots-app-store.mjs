import { execFile } from "node:child_process"
import { mkdir, mkdtemp, realpath, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { dirname, join, resolve } from "node:path"
import { fileURLToPath } from "node:url"
import { promisify } from "node:util"

import { appStoreJobs, appStoreSets } from "./screenshots-ios-lib.mjs"
import { run } from "./screenshots-lib.mjs"

const execute = promisify(execFile)
const root = await realpath(fileURLToPath(new URL("..", import.meta.url)))
const options = parseOptions(process.argv.slice(2))
if (options.help) {
  console.log(`Usage: bun run screenshots:ios:app-store [--output directory] [--reuse-captures]

Captures every App Store device (iPhone 18 Pro, iPad Pro 13-inch, unfolded iPhone Duo) in light and
dark with screenshots:ios:direct, one simulator at a time, then writes both upload sets:
app-store-screenshots/ (the light captures as opaque PNGs) and app-store-screenshots-framed/ (the
dark captures in device mockups under captions). --reuse-captures skips capturing and rebuilds both
sets from the captures already in the output directory.`)
  process.exit(0)
}

const captures = join(options.output, "captures")
if (!options.reuseCaptures) {
  await rm(captures, { recursive: true, force: true })
  for (const { device } of Object.values(appStoreSets)) {
    await run(
      "bun",
      ["scripts/screenshots-ios-direct.mjs", "--device", device, "--output", captures],
      {
        cwd: root
      }
    )
  }
}

const jobs = appStoreJobs(captures, options.output)
for (const set of ["app-store-screenshots", "app-store-screenshots-framed"]) {
  await rm(join(options.output, set), { recursive: true, force: true })
}
for (const job of jobs) await mkdir(dirname(job.output), { recursive: true })
const manifest = join(await mkdtemp(join(tmpdir(), "codevisor-app-store-")), "jobs.json")
await writeFile(manifest, JSON.stringify(jobs))
await execute("xcrun", ["swift", join(root, "scripts/screenshots-app-store.swift"), manifest])
for (const job of jobs) console.log(job.output)

function parseOptions(args) {
  const parsed = { output: resolve(root, "tmp/screenshots/app-store"), reuseCaptures: false }
  for (let index = 0; index < args.length; index++) {
    const flag = args[index]
    if (flag === "--help") return { help: true }
    if (flag === "--reuse-captures") {
      parsed.reuseCaptures = true
      continue
    }
    if (flag !== "--output") throw new Error(`Unknown option: ${flag}`)
    const value = args[++index]
    if (!value || value.startsWith("--")) throw new Error(`Missing value for ${flag}`)
    parsed.output = resolve(root, value)
  }
  return parsed
}
