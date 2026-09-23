#!/usr/bin/env node
// `bun run vnc:tophat`: layer L4 of docs/plans/vnc-validation.md. Builds the
// rig, launches it in the background (no focus stolen), drives it through the
// Accessibility API (scripts/vnc-tophat/rig-ax.swift), captures only the rig's
// window, and writes tmp/vnc-tophat/<time>/summary.json with the screenshots.
// Exit 0 only if every step passed. The terminal running it needs
// Accessibility permission (System Settings → Privacy & Security).
import { spawnSync } from "node:child_process"
import { createHash } from "node:crypto"
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

import { clipboardToken, parseTophatArguments, parseWindow, summarize } from "./vnc-tophat-lib.mjs"

const root = dirname(dirname(fileURLToPath(import.meta.url)))
const bundle = join(root, "tmp/screen-sharing/ScreenSharingRig.app")
const executable = join(bundle, "Contents/MacOS/screen-sharing-rig")
const usage = `Usage: bun run vnc:tophat [--machines loopback,contabo] [--no-build]

Runs the rig through the product path in the background and records window-only screenshots.
"loopback" (default) needs nothing; "contabo" needs Tailscale up and the Contabo VPS reachable.
`

let options
try {
  options = parseTophatArguments(process.argv.slice(2))
} catch (error) {
  process.stderr.write(`${error.message}\n\n${usage}`)
  process.exit(2)
}
if (options.help) {
  process.stdout.write(usage)
  process.exit(0)
}

const run = (command, args, extra = {}) => spawnSync(command, args, { encoding: "utf8", ...extra })
const pause = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms)
const output = join(
  root,
  "tmp/vnc-tophat",
  new Date()
    .toISOString()
    .replaceAll(":", "")
    .replace(/\.\d+Z$/, "Z")
)
mkdirSync(output, { recursive: true })

// The AX helper, compiled once per source revision.
const helperSource = join(root, "scripts/vnc-tophat/rig-ax.swift")
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

const steps = []
let pid
const ax = (...args) => run(helper, [String(pid), ...args])
const step = (name, check) => {
  let result
  try {
    result = check()
  } catch (error) {
    result = { ok: false, detail: error.message }
  }
  const entry = { name, ok: Boolean(result.ok), detail: result.detail ?? "" }
  steps.push(entry)
  process.stdout.write(
    `${entry.ok ? "✔" : "✘"} ${name}${entry.detail ? ` — ${entry.detail}` : ""}\n`
  )
  return entry.ok
}
const axStep = (name, ...args) =>
  step(name, () => {
    const result = ax(...args)
    return { ok: result.status === 0, detail: result.stdout.trim() }
  })
const window = () => parseWindow(ax("window").stdout)
const capture = (name) => {
  const file = join(output, `${name}.png`)
  const result = run("screencapture", ["-x", "-o", "-l", String(window().number), file])
  if (result.status !== 0) throw new Error(`screencapture failed: ${result.stderr}`)
  return file
}
/// Two window captures a moment apart differ when the content is moving.
const moving = (name) => {
  const first = readFileSync(capture(`${name}-a`))
  pause(700)
  const second = readFileSync(capture(`${name}-b`))
  return {
    ok: !first.equals(second),
    detail: first.equals(second) ? "the picture did not change" : ""
  }
}

// One rig instance from this build, launched without taking focus.
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
    // A menu item pressed before its menu is fully open doesn't select; open, choose, check, retry.
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
    // The Loopback server starts at 1280 × 800; after the resize and the viewer's debounce it follows the pane.
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

/// Sends a unique text through the product's clipboard menu and finds it in
/// the reference server's input log; the user's clipboard is restored.
function clipboardStep() {
  // pbcopy/pbpaste read and write text in the locale's encoding.
  const utf8 = { env: { ...process.env, LANG: "en_US.UTF-8", LC_ALL: "en_US.UTF-8" } }
  const saved = run("pbpaste", [], utf8).stdout
  const token = clipboardToken(Date.now())
  try {
    run("pbcopy", [], { input: token, ...utf8 })
    axStep("open the Clipboard menu", "press", "Clipboard")
    axStep("Send Clipboard to Machine", "press", "Send Clipboard to Machine")
    // Leaving the machine closes its connection, so wait for the product to confirm the transfer.
    axStep("the viewer confirms the transfer", "wait", "Text sent to the host", "10")
    axStep("open the server's input log", "select", "Loopback VNC server")
    axStep("the server received the clipboard text", "wait", `clipboard: ${token}`, "5")
    axStep("back to the machine", "select", "Loopback server")
  } finally {
    run("pbcopy", [], { input: saved, ...utf8 })
  }
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
    ax("press", "Connection Details")
    return { ok: shown.status === 0, detail: shown.stdout.trim() }
  })
  step("the Contabo desktop is on screen", () => {
    // Connecting resizes the desktop to the pane; the picture follows within a few seconds.
    let colours = 0
    for (let attempt = 0; attempt < 20; attempt += 1) {
      colours = Number(ax("colours", capture("contabo")).stdout.trim()) || 0
      if (colours > 8)
        return {
          ok: true,
          detail: `${colours} colours in the video after ${attempt + 1} capture(s), 1 s apart`
        }
      pause(1000)
    }
    return {
      ok: false,
      detail: `the video is blank (${colours} colour${colours === 1 ? "" : "s"})`
    }
  })
}
