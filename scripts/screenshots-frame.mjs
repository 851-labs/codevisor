import { execFile } from "node:child_process"
import { mkdir, mkdtemp, realpath, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { dirname, join, resolve } from "node:path"
import { fileURLToPath } from "node:url"
import { promisify } from "node:util"

import { frameJobs } from "./screenshots-ios-lib.mjs"

const execute = promisify(execFile)
const root = await realpath(fileURLToPath(new URL("..", import.meta.url)))
const options = parseOptions(process.argv.slice(2))
if (options.help) {
  console.log(`Usage: bun run screenshots:ios:frame [--input directory] [--output directory] [--appearance dark|light]

Frames the captures from screenshots:ios:direct for the App Store: each one sits in a device mockup
under a short caption, on a dark background, at the size App Store Connect accepts for its slot.`)
  process.exit(0)
}

const jobs = frameJobs(options.input, options.output, options.appearance)
for (const job of jobs) await mkdir(dirname(job.output), { recursive: true })
const manifest = join(await mkdtemp(join(tmpdir(), "codevisor-frame-")), "jobs.json")
await writeFile(manifest, JSON.stringify(jobs))
await execute("xcrun", ["swift", join(root, "scripts/screenshots-frame.swift"), manifest])
for (const job of jobs) console.log(job.output)

function parseOptions(args) {
  const parsed = {
    input: resolve(root, "tmp/screenshots/ios"),
    output: resolve(root, "tmp/screenshots/ios-framed"),
    appearance: "dark"
  }
  for (let index = 0; index < args.length; index++) {
    const flag = args[index]
    if (flag === "--help") return { help: true }
    if (!["--input", "--output", "--appearance"].includes(flag))
      throw new Error(`Unknown option: ${flag}`)
    const value = args[++index]
    if (!value || value.startsWith("--")) throw new Error(`Missing value for ${flag}`)
    parsed[flag.slice(2)] = flag === "--appearance" ? value : resolve(root, value)
  }
  if (!["dark", "light"].includes(parsed.appearance))
    throw new Error("--appearance must be dark or light")
  return parsed
}
