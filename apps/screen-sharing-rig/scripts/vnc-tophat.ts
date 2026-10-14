#!/usr/bin/env node
import { spawnSync, type SpawnSyncOptions } from "node:child_process"
import { createHash } from "node:crypto"
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

import { errorMessage } from "./screen-sharing-rig-lib.ts"
import {
  clipboardToken,
  parseTophatArguments,
  parseWindow,
  summarize,
  type RigWindow,
  type Step,
  type TophatOptions
} from "./vnc-tophat-lib.ts"

const root = dirname(dirname(dirname(dirname(fileURLToPath(import.meta.url)))))
const bundle = join(root, "tmp/screen-sharing/ScreenSharingRig.app")
const executable = join(bundle, "Contents/MacOS/screen-sharing-rig")
const usage = `Usage: bun run vnc:tophat [--machines loopback,contabo] [--no-build]

Runs the rig through the product path in the background and records window-only screenshots.
"loopback" (default) needs nothing; "contabo" needs Tailscale up and the Contabo VPS reachable.
`

let options: TophatOptions
try {
  options = parseTophatArguments(process.argv.slice(2))
} catch (error) {
  process.stderr.write(`${errorMessage(error)}\n\n${usage}`)
  process.exit(2)
}
if (options.help) {
  process.stdout.write(usage)
  process.exit(0)
}

const run = (command: string, args: string[], extra: SpawnSyncOptions = {}) =>
  spawnSync(command, args, { ...extra, encoding: "utf8" })
const pause = (ms: number) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms)
const output = join(
  root,
  "tmp/vnc-tophat",
  new Date()
    .toISOString()
    .replaceAll(":", "")
    .replace(/\.\d+Z$/, "Z")
)
mkdirSync(output, { recursive: true })

const helperSource = join(root, "apps/screen-sharing-rig/scripts/vnc-tophat/rig-ax.swift")
const helperHash = createHash("sha256")
  .update(readFileSync(helperSource))
  .digest("hex")
  .slice(0, 12)
const helper = join(root, "tmp/vnc-tophat", `rig-ax-${helperHash}`)
if (!existsSync(helper)) {
  const compiled = run("swiftc", ["-O", "-o", helper, helperSource])
  if (compiled.status !== 0) throw new Error(`rig-ax failed to compile:\n${compiled.stderr}`)
}

if (options.build) {
  process.stdout.write("Building the rig…\n")
  const built = run("bun", ["run", "screen-sharing:rig", "build", "--debug", "--build-only"], {
    cwd: root
  })
  if (built.status !== 0) {
    process.stderr.write(built.stdout + built.stderr)
    process.exit(1)
  }
}

const steps: Step[] = []
let pid: string | undefined
const ax = (...args: string[]) => run(helper, [String(pid), ...args])
type Check = { ok: boolean; detail?: string }
const step = (name: string, check: () => Check) => {
  let result: Check
  try {
    result = check()
  } catch (error) {
    result = { ok: false, detail: errorMessage(error) }
  }
  const entry = { name, ok: Boolean(result.ok), detail: result.detail ?? "" }
  steps.push(entry)
  process.stdout.write(
    `${entry.ok ? "✔" : "✘"} ${name}${entry.detail ? ` — ${entry.detail}` : ""}\n`
  )
  return entry.ok
}
const axStep = (name: string, ...args: string[]) =>
  step(name, () => {
    const result = ax(...args)
    return { ok: result.status === 0, detail: result.stdout.trim() }
  })
const window = (): RigWindow => parseWindow(ax("window").stdout)
const capture = (name: string) => {
  const file = join(output, `${name}.png`)
  const result = run("screencapture", ["-x", "-o", "-l", String(window().number), file])
  if (result.status !== 0) throw new Error(`screencapture failed: ${result.stderr}`)
  return file
}
const moving = (name: string): Check => {
  const first = readFileSync(capture(`${name}-a`))
  pause(700)
  const second = readFileSync(capture(`${name}-b`))
  return {
    ok: !first.equals(second),
    detail: first.equals(second) ? "the picture did not change" : ""
  }
}

run("pkill", ["-f", executable])
run("open", ["-g", "-n", bundle])
for (let attempt = 0; attempt < 40 && !pid; attempt += 1) {
  pause(250)
  pid = run("pgrep", ["-n", "-f", executable]).stdout.trim() || undefined
}
step("rig launched in the background", () => ({
  ok: Boolean(pid),
  detail: pid ? `pid ${pid}` : "no process"
}))
if (pid) {
  step("window is up", () => {
    for (let attempt = 0; attempt < 40; attempt += 1) {
      if (ax("window").status === 0) return { ok: true, detail: window().title }
      pause(250)
    }
    return { ok: false, detail: "no window" }
  })

  if (options.machines.includes("loopback")) loopbackFlow()
  if (options.machines.includes("contabo")) contaboFlow()

  axStep("quit from the menu bar", "menu", "Quit Codevisor Screen Sharing Rig")
}

const verdict = summarize(steps)
writeFileSync(join(output, "summary.json"), JSON.stringify({ ...verdict, steps }, null, 2))
process.stdout.write(
  `\nvnc:tophat: ${verdict.ok ? "PASS" : "FAIL"} — ${verdict.passed}/${steps.length} steps. Summary and screenshots: ${output}\n`
)
process.exit(verdict.ok ? 0 : 1)

function loopbackFlow() {
  axStep("open Loopback VNC server", "select", "Loopback VNC server")
  step("choose the scroll scene (and confirm the picker shows it)", () => {
    for (let attempt = 1; attempt <= 3; attempt += 1) {
      pause(400)
      ax("press", "Animated desktop")
      pause(700)
      ax("press", "Scene: scroll")
      pause(400)
      if (ax("has", "AXPopUpButton", "Scene: scroll").status === 0)
        return { ok: true, detail: `attempt ${attempt}` }
    }
    return { ok: false, detail: "the picker never showed Scene: scroll" }
  })
  axStep("turn on pointer echo", "press", "Echo pointer input")
  axStep("start the server", "press", "Start")
  axStep("server is serving", "wait", "Serving on 127.0.0.1", "10")
  axStep("view it under Machines", "press", "View")
  step("Loopback server machine is selected", () => {
    for (let attempt = 0; attempt < 40; attempt += 1) {
      if (window().title.startsWith("Loopback server")) return { ok: true, detail: window().title }
      pause(250)
    }
    return { ok: false, detail: window().title }
  })
  step("the scene streams through the product viewer", () => {
    pause(1500)
    return moving("loopback-scroll")
  })
  axStep("View/Control switch present (View)", "press", "View")
  axStep("View/Control switch present (Control)", "press", "Control")
  step("Connection Details reports the VNC route", () => {
    const opened = ax("press", "Connection Details")
    const shown = ax("wait", "VNC · TCP", "5")
    ax("press", "Connection Details")
    return { ok: opened.status === 0 && shown.status === 0, detail: shown.stdout.trim() }
  })
  clipboardStep()
  step("the viewer keeps streaming after a window resize", () => {
    const before = window()
    if (ax("resize", "960", "640").status !== 0) return { ok: false, detail: "resize refused" }
    pause(800)
    const after = window()
    const motion = moving("loopback-resized")
    return {
      ok: after.width !== before.width && motion.ok,
      detail: `${before.width}×${before.height} → ${after.width}×${after.height}${motion.detail ? `; ${motion.detail}` : ""}`
    }
  })
  step("the remote desktop follows the window (ExtendedDesktopSize)", () => {
    for (let attempt = 0; attempt < 12; attempt += 1) {
      pause(500)
      ax("press", "Connection Details")
      const video = ax("texts")
        .stdout.split("\n")
        .find((line) => /^\d+ × \d+$/.test(line.trim()))
      ax("press", "Connection Details")
      if (video && video.trim() !== "1280 × 800")
        return { ok: true, detail: `video ${video.trim()}` }
    }
    return { ok: false, detail: "Connection Details still reports 1280 × 800" }
  })
  axStep("back to the server tab", "select", "Loopback VNC server")
  axStep("stop the server", "press", "Stop")
}

function clipboardStep() {
  const utf8 = { env: { ...process.env, LANG: "en_US.UTF-8", LC_ALL: "en_US.UTF-8" } }
  const saved = run("pbpaste", [], utf8).stdout
  const token = clipboardToken(Date.now())
  try {
    run("pbcopy", [], { input: token, ...utf8 })
    axStep("open the Clipboard menu", "press", "Clipboard")
    axStep("turn off Use Shared Clipboard", "press", "Use Shared Clipboard")
    axStep("open the Clipboard menu again", "press", "Clipboard")
    axStep("Send Clipboard", "press", "Send Clipboard")
    axStep("the viewer confirms the transfer", "wait", "Text sent to the host", "10")
    axStep("open the server's input log", "select", "Loopback VNC server")
    axStep("the server received the clipboard text", "wait", `clipboard: ${token}`, "5")
    axStep("back to the machine", "select", "Loopback server")
  } finally {
    run("pbcopy", [], { input: saved, ...utf8 })
  }
}

function videoSize(): { width: number; height: number } | undefined {
  if (ax("press", "Connection Details").status !== 0) return undefined
  const line = ax("texts")
    .stdout.split("\n")
    .find((text) => /^\d+ × \d+$/.test(text.trim()))
  ax("press", "Connection Details")
  if (!line) return undefined
  const [width = 0, height = 0] = line.trim().split(" × ").map(Number)
  return { width, height }
}

function desktopOnScreen(name: string, file: string) {
  step(name, () => {
    let colours = 0
    let black = 1
    for (let attempt = 0; attempt < 20; attempt += 1) {
      ;[colours = 0, black = 1] = ax("colours", capture(file)).stdout.trim().split(" ").map(Number)
      if (colours > 8 && black < 0.95)
        return {
          ok: true,
          detail: `${colours} colours, darkest half ${Math.round(black * 100)}% black, after ${attempt + 1} capture(s) 1 s apart`
        }
      pause(1000)
    }
    return {
      ok: false,
      detail: `no picture: ${colours} colours, darkest half ${Math.round(black * 100)}% black`
    }
  })
}

function contaboFlow() {
  axStep("open Contabo VPS", "select", "Contabo VPS")
  axStep("Contabo VPS is selected", "wait", "Contabo VPS", "20")
  step("Connection Details reports VNC over WebSocket", () => {
    for (let attempt = 0; attempt < 40; attempt += 1) {
      if (ax("press", "Connection Details").status === 0) break
      pause(500)
    }
    const shown = ax("wait", "VNC · WebSocket", "10")
    const route =
      ax("texts")
        .stdout.split("\n")
        .find((text) => text.includes("VNC · WebSocket")) ?? ""
    ax("press", "Connection Details")
    return { ok: shown.status === 0, detail: route.trim() }
  })
  desktopOnScreen("the Contabo desktop is on screen", "contabo")
  const start = window()
  type Size = { width: number; height: number }
  const settle = (predicate: (size: Size) => boolean, what: string) => {
    for (let attempt = 0; attempt < 30; attempt += 1) {
      pause(500)
      const size = videoSize()
      if (size && predicate(size)) return { ok: true, detail: `${size.width} × ${size.height}` }
    }
    return { ok: false, detail: `${what}: ${JSON.stringify(videoSize())}` }
  }
  let fixed: Size | undefined
  try {
    axStep("turn Dynamic Resolution off", "press", "Dynamic Resolution")
    fixed = videoSize()
    step("off: the desktop keeps its size when the window changes", () => {
      if (ax("resize", String(start.width - 200), String(start.height - 120)).status !== 0)
        return { ok: false, detail: "resize refused" }
      pause(3000)
      const size = videoSize()
      return {
        ok: Boolean(fixed && size && size.width === fixed.width && size.height === fixed.height),
        detail: `${JSON.stringify(fixed)} → ${JSON.stringify(size)}`
      }
    })
  } finally {
    axStep("turn Dynamic Resolution back on", "press", "Dynamic Resolution")
  }
  const fixedWidth = fixed?.width ?? 0
  step("on: the desktop follows the smaller window", () =>
    settle((size: Size) => size.width !== fixedWidth, "never followed")
  )
  step("on: and back when the window grows again", () => {
    ax("resize", String(start.width), String(start.height))
    return settle((size: Size) => Math.abs(size.width - fixedWidth) <= 2, "never grew back")
  })
  {
    step("the route after streaming", () => {
      pause(20000)
      if (ax("press", "Connection Details").status !== 0)
        return { ok: true, detail: "Connection Details unavailable" }
      const texts = ax("texts")
        .stdout.split("\n")
        .map((text) => text.trim())
      ax("press", "Connection Details")
      const route = texts.find((text) => text.includes("VNC · ")) ?? ""
      const at = texts.indexOf("Receiving")
      return { ok: true, detail: `${route}${at >= 0 ? `; receiving ${texts[at + 1]}` : ""}` }
    })
  }
}
