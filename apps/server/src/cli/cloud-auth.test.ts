import type { FetchLike } from "@codevisor/cloud-client"
import { describe, expect, it, vi } from "vitest"
import {
  authLoginCommand,
  authLogoutCommand,
  authStatusCommand,
  cloudCredentialsPath,
  DEFAULT_CLOUD_URL,
  readCloudCredentials
} from "./cloud-auth.js"
import type { CliDeps, ExecResult } from "./support.js"

const failure: ExecResult = { code: 1, stdout: "", stderr: "" }

interface World {
  deps: CliDeps
  logs: string[]
  errors: string[]
  files: Map<string, string>
}

const makeWorld = (
  options: { files?: Record<string, string>; env?: Record<string, string> } = {}
): World => {
  const logs: string[] = []
  const errors: string[] = []
  const files = new Map<string, string>(Object.entries(options.files ?? {}))
  const deps: CliDeps = {
    exec: () => Promise.resolve(failure),
    execInteractive: () => Promise.resolve(0),
    spawnDetachedServer: () => Promise.resolve(4242),
    fetchJson: () => Promise.resolve(undefined),
    readTextFile: (path) => files.get(path),
    writeTextFile: (path, contents) => void files.set(path, contents),
    removeFile: (path) => void files.delete(path),
    processAlive: () => false,
    signal: () => true,
    sleep: () => Promise.resolve(),
    env: options.env ?? {},
    isRoot: false,
    installedVersion: () => undefined,
    dataDir: "/home/user/.codevisor/data",
    logsDir: "/home/user/.codevisor/logs",
    log: (line) => void logs.push(line),
    error: (line) => void errors.push(line)
  }
  return { deps, logs, errors, files }
}

const credentials = {
  serverUrl: "https://cloud.example",
  deviceId: "device-1",
  publicKey: "pub",
  secretKey: "sec",
  apiKey: "key"
}

const credentialFiles = {
  "/home/user/.codevisor/data/cloud.json": JSON.stringify(credentials)
}

const jsonResponse = (body: unknown, status = 200): Response =>
  new Response(JSON.stringify(body), { status })

const instanceBody = {
  service: "codevisor-cloud",
  instance: "Test Cloud",
  version: "0.1.0",
  protocols: [1],
  authProviders: ["dev"]
}

/// Scripted fetch: responses consumed per-endpoint in order (last repeats).
const scriptedFetch = (script: Record<string, Response[]>): FetchLike => {
  const counts = new Map<string, number>()
  return (input) => {
    const key = new URL(input).pathname
    const responses = script[key]
    if (responses === undefined) throw new Error(`unexpected fetch: ${key}`)
    const index = counts.get(key) ?? 0
    counts.set(key, index + 1)
    return Promise.resolve(responses[Math.min(index, responses.length - 1)]!.clone())
  }
}

const grantBody = (overrides: Record<string, unknown> = {}) => ({
  device_code: "dc",
  user_code: "AB12-CD34",
  verification_uri: "/device",
  verification_uri_complete: "https://cloud.example/device?user_code=AB12-CD34",
  interval: 1,
  expires_in: 60,
  ...overrides
})

describe("readCloudCredentials", () => {
  it("parses valid credentials and rejects everything else", () => {
    expect(readCloudCredentials(makeWorld({ files: credentialFiles }).deps)).toEqual(credentials)
    expect(readCloudCredentials(makeWorld().deps)).toBeUndefined()
    expect(
      readCloudCredentials(
        makeWorld({ files: { "/home/user/.codevisor/data/cloud.json": "not json" } }).deps
      )
    ).toBeUndefined()
    expect(
      readCloudCredentials(
        makeWorld({ files: { "/home/user/.codevisor/data/cloud.json": '{"serverUrl":"x"}' } }).deps
      )
    ).toBeUndefined()
  })
})

describe("authLoginCommand", () => {
  it("connects after approval and persists credentials", async () => {
    const world = makeWorld({ env: { HOSTNAME: "dev-vps" } })
    const fetchImpl = scriptedFetch({
      "/.well-known/codevisor": [jsonResponse(instanceBody)],
      "/api/auth/device/code": [jsonResponse(grantBody())],
      "/api/auth/device/token": [
        jsonResponse({ error: "authorization_pending" }, 400),
        jsonResponse({ access_token: "session" })
      ],
      "/api/auth/api-key/create": [jsonResponse({ key: "api-key" })]
    })
    const code = await authLoginCommand(world.deps, {
      server: "https://cloud.example/",
      fetchImpl
    })
    expect(code).toBe(0)
    expect(world.logs.join("\n")).toContain("AB12-CD34")
    expect(world.logs.join("\n")).toContain("Connected as dev-vps")
    const stored = JSON.parse(world.files.get(cloudCredentialsPath(world.deps))!) as {
      serverUrl: string
      apiKey: string
    }
    expect(stored.serverUrl).toBe("https://cloud.example")
    expect(stored.apiKey).toBe("api-key")
  })

  it("uses the fallback verification uri, machine name option, and slow-down backoff", async () => {
    const world = makeWorld()
    const fetchImpl = scriptedFetch({
      "/.well-known/codevisor": [jsonResponse(instanceBody)],
      "/api/auth/device/code": [jsonResponse(grantBody({ verification_uri_complete: undefined }))],
      "/api/auth/device/token": [
        jsonResponse({ error: "slow_down" }, 400),
        jsonResponse({ access_token: "session" })
      ],
      "/api/auth/api-key/create": [jsonResponse({ key: "api-key" })]
    })
    const code = await authLoginCommand(world.deps, {
      server: "https://cloud.example",
      fetchImpl,
      machineName: "named-by-flag"
    })
    expect(code).toBe(0)
    expect(world.logs.join("\n")).toContain("https://cloud.example/device")
    expect(world.logs.join("\n")).toContain("Connected as named-by-flag")
  })

  it("defaults the machine name when no hostname is known", async () => {
    const world = makeWorld()
    const fetchImpl = scriptedFetch({
      "/.well-known/codevisor": [jsonResponse(instanceBody)],
      "/api/auth/device/code": [jsonResponse(grantBody())],
      "/api/auth/device/token": [jsonResponse({ access_token: "session" })],
      "/api/auth/api-key/create": [jsonResponse({ key: "api-key" })]
    })
    expect(await authLoginCommand(world.deps, { server: "https://cloud.example", fetchImpl })).toBe(
      0
    )
    expect(world.logs.join("\n")).toContain("Connected as machine")
  })

  it("reports denial and expiry outcomes", async () => {
    for (const [error, message] of [
      ["access_denied", "denied"],
      ["expired_token", "expired"]
    ] as const) {
      const world = makeWorld()
      const fetchImpl = scriptedFetch({
        "/.well-known/codevisor": [jsonResponse(instanceBody)],
        "/api/auth/device/code": [jsonResponse(grantBody())],
        "/api/auth/device/token": [jsonResponse({ error }, 400)]
      })
      expect(
        await authLoginCommand(world.deps, { server: "https://cloud.example", fetchImpl })
      ).toBe(1)
      expect(world.errors.join("\n")).toContain(message)
    }
  })

  it("gives up when the grant deadline passes while pending", async () => {
    const world = makeWorld()
    const fetchImpl = scriptedFetch({
      "/.well-known/codevisor": [jsonResponse(instanceBody)],
      "/api/auth/device/code": [jsonResponse(grantBody({ interval: 10, expires_in: 0.001 }))],
      "/api/auth/device/token": [jsonResponse({ error: "authorization_pending" }, 400)]
    })
    expect(await authLoginCommand(world.deps, { server: "https://cloud.example", fetchImpl })).toBe(
      1
    )
    expect(world.errors.join("\n")).toContain("expired")
  })

  it("refuses when already connected, and surfaces failures", async () => {
    const connected = makeWorld({ files: credentialFiles })
    expect(await authLoginCommand(connected.deps)).toBe(0)
    expect(connected.logs.join("\n")).toContain("already connected")

    const apiError = makeWorld()
    expect(
      await authLoginCommand(apiError.deps, {
        server: "https://cloud.example",
        fetchImpl: scriptedFetch({ "/.well-known/codevisor": [jsonResponse({}, 503)] })
      })
    ).toBe(1)
    expect(apiError.errors.join("\n")).toContain("status 503")

    const thrown = makeWorld()
    expect(
      await authLoginCommand(thrown.deps, {
        server: "https://cloud.example",
        fetchImpl: () => Promise.reject(new Error("network down"))
      })
    ).toBe(1)
    expect(thrown.errors.join("\n")).toContain("network down")

    const nonError = makeWorld()
    expect(
      await authLoginCommand(nonError.deps, {
        server: "https://cloud.example",
        // eslint-disable-next-line prefer-promise-reject-errors
        fetchImpl: () => Promise.reject("boom")
      })
    ).toBe(1)
    expect(nonError.errors.join("\n")).toContain("boom")
  })

  it("resolves the server from env or the hosted default", async () => {
    const urls: string[] = []
    const recordingFetch: FetchLike = (input) => {
      urls.push(input)
      return Promise.resolve(jsonResponse({}, 500))
    }
    const fromEnv = makeWorld({ env: { CODEVISOR_CLOUD_URL: "https://custom.example" } })
    await authLoginCommand(fromEnv.deps, { fetchImpl: recordingFetch })
    expect(urls[0]).toBe("https://custom.example/.well-known/codevisor")

    const fromDefault = makeWorld()
    await authLoginCommand(fromDefault.deps, { fetchImpl: recordingFetch })
    expect(urls[1]).toBe(`${DEFAULT_CLOUD_URL}/.well-known/codevisor`)
  })
})

describe("authStatusCommand", () => {
  it("reports disconnected, connected, and unreachable states", async () => {
    const disconnected = makeWorld()
    expect(await authStatusCommand(disconnected.deps)).toBe(0)
    expect(disconnected.logs.join("\n")).toContain("not connected")

    const connected = makeWorld({ files: credentialFiles })
    expect(
      await authStatusCommand(connected.deps, {
        fetchImpl: scriptedFetch({ "/.well-known/codevisor": [jsonResponse(instanceBody)] })
      })
    ).toBe(0)
    expect(connected.logs.join("\n")).toContain("Test Cloud (v0.1.0)")
    expect(connected.logs.join("\n")).toContain("device-1")

    const unreachable = makeWorld({ files: credentialFiles })
    expect(
      await authStatusCommand(unreachable.deps, {
        fetchImpl: () => Promise.reject(new Error("down"))
      })
    ).toBe(0)
    expect(unreachable.logs.join("\n")).toContain("unreachable")
  })
})

describe("default fetch", () => {
  it("falls back to globalThis.fetch when none is injected", async () => {
    const world = makeWorld({ files: credentialFiles })
    vi.stubGlobal("fetch", () => Promise.resolve(jsonResponse(instanceBody)))
    try {
      expect(await authStatusCommand(world.deps)).toBe(0)
      expect(world.logs.join("\n")).toContain("Test Cloud")
    } finally {
      vi.unstubAllGlobals()
    }
  })
})

describe("authLogoutCommand", () => {
  it("removes stored credentials and handles the disconnected case", async () => {
    const connected = makeWorld({ files: credentialFiles })
    expect(await authLogoutCommand(connected.deps)).toBe(0)
    expect(connected.files.has(cloudCredentialsPath(connected.deps))).toBe(false)
    expect(connected.logs.join("\n")).toContain("Disconnected")

    const disconnected = makeWorld()
    expect(await authLogoutCommand(disconnected.deps)).toBe(0)
    expect(disconnected.logs.join("\n")).toContain("not connected")
  })
})
