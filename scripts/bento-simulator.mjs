import { execFile, spawn } from "node:child_process"
import { mkdtemp, open, readFile, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { promisify } from "node:util"

import { devices, selectRuntime } from "./screenshots-ios-lib.mjs"

const execute = promisify(execFile)
const device = devices["iphone-18-pro"]
const statusBarTime = new Date(2001, 7, 8, 14, 5).toISOString()
const pagePort = 3000
const pageRenderSeconds = 8
const pageRequestTimeoutSeconds = 20
const pageAttempts = 3
const appearances = ["light", "dark"]
const pageSource = "apps/shared/Screenshots/AppStoreScreenshotPage.swift"

export async function prepareSimulator(root) {
  const scratch = await mkdtemp(join(tmpdir(), "codevisor-bento-simulator-"))
  const { runtimes } = JSON.parse(await simctl("list", "runtimes", "--json"))
  const runtime = selectRuntime(runtimes, [device])
  const requests = join(scratch, "requests.log")
  const requestLog = await open(requests, "w")
  const page = spawn(
    "python3",
    ["-m", "http.server", String(pagePort), "--bind", "127.0.0.1", "--directory", scratch],
    { stdio: ["ignore", "ignore", requestLog.fd] }
  )
  try {
    const html = await emojisPage(root)
    const screens = {}
    const settings = {}
    let fixture
    for (const appearance of appearances) {
      await writeFile(join(scratch, `warm-up-${appearance}.html`), html(appearance))
      await writeFile(join(scratch, `${appearance}.html`), html(appearance))
      screens[appearance] = join(scratch, `screen-${appearance}.png`)
      fixture = await withSimulator(runtime, async (udid) => {
        await simctl("ui", udid, "appearance", appearance)
        await openPage(udid, `warm-up-${appearance}.html`, requests)
        await openPage(udid, `${appearance}.html`, requests)
        await simctl("io", udid, "screenshot", screens[appearance])
        const { stdout } = await execute("bun", ["scripts/bento-simulator-fixture.mjs", udid], {
          cwd: root,
          maxBuffer: 64 * 1024 * 1024
        })
        return JSON.parse(stdout)
      })
      settings[appearance] = fixture.settings
    }
    const file = join(scratch, "fixture.json")
    await writeFile(file, JSON.stringify({ ...fixture, settings, screens }))
    return { environment: { CODEVISOR_BENTO_SIMULATOR_FIXTURE: file }, scratch }
  } finally {
    page.kill("SIGTERM")
    await requestLog.close()
  }
}

async function withSimulator(runtime, work) {
  const udid = await simctl("create", device.name, device.type, runtime.identifier)
  try {
    await prepareDevice(udid)
    return await work(udid)
  } finally {
    await simctl("shutdown", udid).catch(() => {})
    await simctl("delete", udid)
  }
}

async function openPage(udid, path, requests) {
  for (let attempt = 0; attempt < pageAttempts; attempt++) {
    await simctl("openurl", udid, `http://localhost:${pagePort}/${path}`).catch(() => {})
    for (let waited = 0; waited < pageRequestTimeoutSeconds; waited++) {
      await sleep(1)
      if ((await readFile(requests, "utf8")).includes(`GET /${path}`)) {
        await sleep(pageRenderSeconds)
        return
      }
    }
  }
  throw new Error(`Safari never requested ${path} on the throwaway simulator`)
}

async function prepareDevice(udid) {
  await boot(udid)
  await simctl("spawn", udid, "defaults", "write", "-g", "AppleICUForce24HourTime", "-bool", "YES")
  await simctl("shutdown", udid)
  await boot(udid)
  await simctl(
    "status_bar",
    udid,
    "override",
    "--dataNetwork",
    "wifi",
    "--wifiMode",
    "active",
    "--wifiBars",
    "3",
    "--batteryState",
    "discharging",
    "--batteryLevel",
    "100"
  )
  await simctl("status_bar", udid, "override", "--time", statusBarTime)
}

async function emojisPage(root) {
  const source = await readFile(join(root, pageSource), "utf8")
  const start = source.indexOf('"""') + 3
  const body = source.slice(start, source.indexOf('"""', start))
  const copyTitle = /static let copyButtonTitle = "([^"]*)"/.exec(source)?.[1] ?? ""
  return (appearance) => {
    const html = body
      .split("\n")
      .map((line) => line.replace(/^ {6}/, ""))
      .join("\n")
      .replaceAll(
        /\\\(AppStoreScreenshotData\.colorScheme == \.dark \? "([^"]*)" : "([^"]*)"\)/g,
        (_, dark, light) => (appearance === "dark" ? dark : light)
      )
      .replaceAll(String.raw`\(copyButtonTitle)`, copyTitle)
    if (html.includes(String.raw`\(`)) throw new Error(`Unexpected interpolation in ${pageSource}`)
    return html.trim()
  }
}

async function boot(udid) {
  await simctl("boot", udid)
  await simctl("bootstatus", udid, "-b")
}

async function simctl(...args) {
  return (
    await execute("xcrun", ["simctl", ...args], { maxBuffer: 16 * 1024 * 1024 })
  ).stdout.trim()
}

function sleep(seconds) {
  return new Promise((wake) => setTimeout(wake, seconds * 1000))
}
