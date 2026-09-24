#!/usr/bin/env node
// `bun run vnc:frame-clock`: the cross-app frame clock (851-2358). Serves the
// host page (apps/screen-sharing-rig/frame-clock/index.html) on this Mac's
// network, then captures each named viewer window with
// `screen-sharing-rig frame-clock` and writes summary.json, the per-window
// samples and report.md under tmp/vnc-frame-clock/<time>/ (or --out).
//
// Open the printed URL on the machine being viewed (full screen), then click
// the page, or reload it, once the capture says it's waiting: the strip turns
// orange for a few seconds and every window calibrates on it. Only the named
// windows are captured.
import { spawn } from "node:child_process"
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { createServer } from "node:http"
import { networkInterfaces } from "node:os"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

import { errorMessage } from "./screen-sharing-rig-lib.ts"
import {
  frameClockReport,
  parseFrameClockArguments,
  type FrameClockSummary
} from "./vnc-frame-clock-lib.ts"

const root = dirname(dirname(dirname(dirname(fileURLToPath(import.meta.url)))))
const pageDirectory = join(root, "apps/screen-sharing-rig/frame-clock")
const rig = join(root, "tmp/screen-sharing/ScreenSharingRig.app/Contents/MacOS/screen-sharing-rig")

function lanAddress(): string {
  for (const addresses of Object.values(networkInterfaces())) {
    for (const address of addresses ?? []) {
      if (address.family === "IPv4" && !address.internal) return address.address
    }
  }
  return "localhost"
}

async function main(): Promise<void> {
  const options = parseFrameClockArguments(process.argv.slice(2))
  if (options === "help") {
    console.log(`Usage: bun run vnc:frame-clock [--app BUNDLE_ID]… [--seconds 60] [--mode video|scroll|type|still]
                               [--port 8765] [--out DIR] [--label TEXT]
Defaults to the rig and Apple Screen Sharing. Build the rig first (bun run screen-sharing:rig build --build-only).`)
    return
  }
  if (!existsSync(rig))
    throw new Error(`no rig build at ${rig}: run bun run screen-sharing:rig build --build-only`)
  const page = readFileSync(join(pageDirectory, "index.html"))
  // Served for the whole capture, so the page can be reloaded to recalibrate.
  const server = createServer((_, response) => {
    response.writeHead(200, { "content-type": "text/html; charset=utf-8" })
    response.end(page)
  })
  await new Promise<void>((resolve) => server.listen(options.port, "0.0.0.0", resolve))
  const out =
    options.out ?? join(root, "tmp/vnc-frame-clock", new Date().toISOString().replaceAll(":", "-"))
  mkdirSync(out, { recursive: true })
  console.log(
    `Open http://${lanAddress()}:${options.port}/?mode=${options.mode} on the viewed machine, full screen.`
  )
  console.log(
    "Then click the page (or reload it) once the capture below is waiting; it calibrates on the orange strip."
  )
  const capture = spawn(
    rig,
    [
      "frame-clock",
      ...options.apps.flatMap((app) => ["--app", app]),
      "--seconds",
      String(options.seconds),
      "--out",
      out
    ],
    { stdio: ["ignore", "pipe", "inherit"] }
  )
  let stdout = ""
  capture.stdout.setEncoding("utf8").on("data", (chunk: string) => (stdout += chunk))
  const status = await new Promise<number | null>((resolve) => capture.on("close", resolve))
  server.close()
  if (status !== 0) throw new Error(`frame-clock capture failed (exit ${status})`)
  const summary = JSON.parse(stdout) as FrameClockSummary
  writeFileSync(join(out, "summary.json"), JSON.stringify(summary, null, 2) + "\n")
  const report = frameClockReport(summary, {
    mode: options.mode,
    ...(options.label ? { label: options.label } : {})
  })
  writeFileSync(join(out, "report.md"), report)
  console.log(report)
  console.log(`Written to ${out}`)
}

main().catch((error: unknown) => {
  console.error(`vnc:frame-clock: ${errorMessage(error)}`)
  process.exit(1)
})
