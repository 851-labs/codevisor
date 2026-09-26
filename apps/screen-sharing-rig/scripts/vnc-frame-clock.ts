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
  clockOffset,
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

/// The host's clock minus this Mac's (ms), over one SSH connection so each sample costs a
/// network round trip, not a process start: tuftlord answers `time.time()` per line.
async function measureClockOffset(
  host: string,
  hostKeyAlias: string | undefined
): Promise<{ offsetMs: number; roundTripMs: number }> {
  const ssh = spawn(
    "ssh",
    [
      "-o",
      "BatchMode=yes",
      ...(hostKeyAlias === undefined ? [] : ["-o", `HostKeyAlias=${hostKeyAlias}`]),
      host,
      `python3 -u -c 'import sys,time\nfor l in sys.stdin: print(repr(time.time()), flush=True)'`
    ],
    { stdio: ["pipe", "pipe", "inherit"] }
  )
  const lines: string[] = []
  let waiting: ((line: string) => void) | undefined
  let buffered = ""
  ssh.stdout.setEncoding("utf8").on("data", (chunk: string) => {
    buffered += chunk
    let index: number
    while ((index = buffered.indexOf("\n")) >= 0) {
      const line = buffered.slice(0, index)
      buffered = buffered.slice(index + 1)
      if (waiting === undefined) lines.push(line)
      else {
        const resolve = waiting
        waiting = undefined
        resolve(line)
      }
    }
  })
  const next = () =>
    new Promise<string>((resolve) => {
      const line = lines.shift()
      if (line === undefined) waiting = resolve
      else resolve(line)
    })
  const samples: { sent: number; host: number; received: number }[] = []
  for (let index = 0; index < 40; index += 1) {
    const sent = Date.now() / 1000
    ssh.stdin.write("x\n")
    const host = Number(await next())
    const received = Date.now() / 1000
    if (index >= 3) samples.push({ sent, host, received })
  }
  ssh.stdin.end()
  const offset = clockOffset(samples)
  if (offset === undefined) throw new Error(`no clock samples from ${host}`)
  return offset
}

async function main(): Promise<void> {
  const options = parseFrameClockArguments(process.argv.slice(2))
  if (options === "help") {
    console.log(`Usage: bun run vnc:frame-clock [--app BUNDLE_ID]… [--seconds 60] [--mode video|scroll|type|still]
                               [--port 8765] [--out DIR] [--label TEXT] [--host-ssh USER@HOST]
                               [--host-key-alias NAME] [--page-host ADDRESS]
--page-host is the address the viewed Mac opens the page at (this Mac's Tailscale address when the two are on different networks).
--host-ssh measures the viewed Mac's clock offset and reports each viewer's image age (open the URL with &clock=epoch).
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
  const clock =
    options.hostSsh === undefined
      ? undefined
      : await measureClockOffset(options.hostSsh, options.hostKeyAlias)
  if (clock !== undefined) {
    console.log(
      `${options.hostSsh} clock: ${clock.offsetMs.toFixed(1)} ms ahead of this Mac (± ${(clock.roundTripMs / 2).toFixed(1)} ms)`
    )
  }
  console.log(
    `Open http://${options.pageHost ?? lanAddress()}:${options.port}/?mode=${options.mode}${clock === undefined ? "" : "&clock=epoch"} on the viewed machine, full screen.`
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
      out,
      ...(clock === undefined ? [] : ["--host-offset-ms", clock.offsetMs.toFixed(2)])
    ],
    { stdio: ["ignore", "pipe", "inherit"] }
  )
  let stdout = ""
  capture.stdout.setEncoding("utf8").on("data", (chunk: string) => (stdout += chunk))
  const status = await new Promise<number | null>((resolve) => capture.on("close", resolve))
  server.close()
  if (status !== 0) throw new Error(`frame-clock capture failed (exit ${status})`)
  const summary = JSON.parse(stdout) as FrameClockSummary
  if (clock !== undefined) summary.clock = clock
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
