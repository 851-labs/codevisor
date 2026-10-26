import { execFile, spawn } from "node:child_process"
import { mkdtemp, open, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { promisify } from "node:util"

import { delay, describeExit, waitForExit } from "./dev-shared.mjs"
import {
  devices,
  prepareThrowawaySimulator,
  selectRuntime,
  simctl
} from "./screenshots-ios-lib.mjs"

const execute = promisify(execFile)
const device = devices["iphone-18-pro"]
const pageRenderSeconds = 8
const pageRequestTimeoutSeconds = 20
const pageAttempts = 3
const appearances = ["light", "dark"]
const pageSource = "apps/shared/Screenshots/AppStoreScreenshotPage.swift"

export async function prepareSimulator(root) {
  const scratch = await mkdtemp(join(tmpdir(), "codevisor-bento-simulator-"))
  const requests = join(scratch, "requests.log")
  let requestLog
  let server
  let prepared
  try {
    const { runtimes } = JSON.parse(await simctl("list", "runtimes", "--json"))
    const runtime = selectRuntime(runtimes, [device])
    requestLog = await open(requests, "w")
    server = spawn(
      "python3",
      ["-u", "-m", "http.server", "0", "--bind", "127.0.0.1", "--directory", scratch],
      { stdio: ["ignore", "pipe", requestLog.fd] }
    )
    const port = await listeningPort(server)
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
        await openPage(udid, port, `warm-up-${appearance}.html`, requests)
        await openPage(udid, port, `${appearance}.html`, requests)
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
    prepared = {
      environment: { CODEVISOR_BENTO_SIMULATOR_FIXTURE: file },
      scratch
    }
    return prepared
  } finally {
    if (server !== undefined) {
      server.kill("SIGTERM")
      await waitForExit(server)
    }
    await requestLog?.close()
    if (prepared === undefined) await rm(scratch, { recursive: true, force: true })
  }
}

function listeningPort(server) {
  return new Promise((resolve, reject) => {
    let output = ""
    server.stdout.on("data", (chunk) => {
      output += chunk
      const port = / port (\d+)/.exec(output)?.[1]
      if (port !== undefined) resolve(Number(port))
    })
    server.once("error", reject)
    server.once("exit", (code, signal) =>
      reject(new Error(`The page server exited with ${describeExit({ code, signal })}`))
    )
  })
}

async function withSimulator(runtime, work) {
  const udid = await simctl("create", device.name, device.type, runtime.identifier)
  try {
    await prepareThrowawaySimulator(udid)
    return await work(udid)
  } finally {
    await simctl("shutdown", udid).catch(() => {})
    await simctl("delete", udid)
  }
}

async function openPage(udid, port, path, requests) {
  for (let attempt = 0; attempt < pageAttempts; attempt++) {
    await simctl("openurl", udid, `http://localhost:${port}/${path}`).catch(() => {})
    for (let waited = 0; waited < pageRequestTimeoutSeconds; waited++) {
      await delay(1000)
      if ((await readFile(requests, "utf8")).includes(`GET /${path}`)) {
        await delay(pageRenderSeconds * 1000)
        return
      }
    }
  }
  throw new Error(`Safari never requested ${path} on the throwaway simulator`)
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
