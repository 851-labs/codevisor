import type { FetchLike } from "@codevisor/cloud-client"
import { describe, expect, it, vi } from "vitest"

import {
  authLoginCommand,
  authLogoutCommand,
  authStatusCommand,
  DEFAULT_CLOUD_URL
} from "./cloud-auth.js"
import type { CloudRegistration } from "./cloud-control.js"
import type { CliDeps, ExecResult } from "./support.js"

const failure: ExecResult = { code: 1, stdout: "", stderr: "" }

interface World {
  deps: CliDeps
  logs: string[]
  errors: string[]
  files: Map<string, string>
  httpCalls: Array<{ url: string; body?: unknown }>
}

const makeWorld = (
  options: {
    registration?: CloudRegistration
    files?: Record<string, string>
    env?: Record<string, string>
  } = {}
): World => {
  const logs: string[] = []
  const errors: string[] = []
  const files = new Map<string, string>(Object.entries(options.files ?? {}))
  let registration: CloudRegistration = options.registration ?? {}
  const httpCalls: Array<{ url: string; body?: unknown }> = []
  const deps: CliDeps = {
    exec: () => Promise.resolve(failure),
    execInteractive: () => Promise.resolve(0),
    spawnDetachedServer: () => Promise.resolve(4242),
    fetchJson: async (url, init) => {
      httpCalls.push({ url, body: init?.body })
      if (url.endsWith("/v1/cloud/connect")) {
        registration = {
          deviceId: "device-1",
          serverUrl: "https://cloud.example",
          state: "connected",
          managedBy: "external"
        }
        return { status: 200, body: { deviceId: registration.deviceId } }
      }
      if (url.endsWith("/v1/cloud/disconnect")) {
        registration = {}
        return { status: 200, body: { ok: true } }
      }
      if (url.endsWith("/v1/cloud")) return { status: 200, body: registration }
      return undefined
    },
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
  return { deps, logs, errors, files, httpCalls }
}

const connectedRegistration: CloudRegistration = {
  serverUrl: "https://cloud.example",
  deviceId: "device-1",
  state: "connected"
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

describe("authLoginCommand", () => {
  it("reports server provisioning failures without announcing success", async () => {
    for (const response of [
      undefined,
      { status: 502, body: { error: "credential rejected" } },
      { status: 200, body: {} }
    ]) {
      const world = makeWorld()
      const deps: CliDeps = {
        ...world.deps,
        fetchJson: (url, init) =>
          url.endsWith("/connect") ? Promise.resolve(response) : world.deps.fetchJson(url, init)
      }
      expect(await authLoginCommand(deps, { fetchImpl: loginScript() })).toBe(1)
      expect(world.errors.join("\n")).toContain("Cloud login failed")
      expect(world.logs.join("\n")).not.toContain("✓ Connected")
      expect(world.files.size).toBe(0)
    }
    const existing = makeWorld({ registration: { deviceId: "device-1", state: "connected" } })
    expect(await authLoginCommand(existing.deps)).toBe(0)
    expect(existing.logs.join("\n")).toContain("already connected to Codevisor Cloud")
  })
  it("connects through the server after approval without writing CLI credentials", async () => {
    const world = makeWorld({ env: { HOSTNAME: "dev-vps" } })
    const fetchImpl = scriptedFetch({
      "/.well-known/codevisor": [jsonResponse(instanceBody)],
      "/api/auth/device/code": [jsonResponse(grantBody())],
      "/api/auth/device/token": [
        jsonResponse({ error: "authorization_pending" }, 400),
        jsonResponse({ access_token: "session" })
      ]
    })
    const code = await authLoginCommand(world.deps, {
      server: "https://cloud.example/",
      fetchImpl
    })
    expect(code).toBe(0)
    expect(world.logs.join("\n")).toContain("AB12-CD34")
    expect(world.logs.join("\n")).toContain("Connected as dev-vps")
    expect(world.httpCalls.find((call) => call.url.endsWith("/connect"))).toEqual({
      url: "http://127.0.0.1:49361/v1/cloud/connect",
      body: {
        serverUrl: "https://cloud.example",
        sessionToken: "session",
        machineName: "dev-vps",
        managedBy: "external"
      }
    })
    expect(world.files.size).toBe(0)
  })

  it("uses the fallback verification uri, machine name option, and slow-down backoff", async () => {
    const world = makeWorld()
    const fetchImpl = scriptedFetch({
      "/.well-known/codevisor": [jsonResponse(instanceBody)],
      "/api/auth/device/code": [jsonResponse(grantBody({ verification_uri_complete: undefined }))],
      "/api/auth/device/token": [
        jsonResponse({ error: "slow_down" }, 400),
        jsonResponse({ access_token: "session" })
      ]
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
      "/api/auth/device/token": [jsonResponse({ access_token: "session" })]
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
    const connected = makeWorld({ registration: connectedRegistration })
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
  it("reports the server's live registration and relay state", async () => {
    const disconnected = makeWorld()
    expect(await authStatusCommand(disconnected.deps)).toBe(0)
    expect(disconnected.logs.join("\n")).toContain("not connected")
    const connected = makeWorld({ registration: connectedRegistration })
    expect(await authStatusCommand(connected.deps, { port: 54321 })).toBe(0)
    expect(connected.logs.join("\n")).toContain("relay:     connected")
    expect(connected.httpCalls[0]?.url).toContain(":54321/")
    for (const state of ["reconnecting", "revoked", "unsupported-protocol", undefined]) {
      const world = makeWorld({
        registration: { deviceId: "device-1", ...(state === undefined ? {} : { state }) }
      })
      expect(await authStatusCommand(world.deps)).toBe(1)
      expect(world.logs[0]).toContain("Registered with")
      expect(world.logs.join("\n")).toContain(state ?? "unknown")
    }
  })

  it("does not claim that a stranded credential file means the server is connected", async () => {
    const world = makeWorld({
      files: { "/home/user/.codevisor/data/cloud.json": "old credential" }
    })
    expect(await authStatusCommand({ ...world.deps, fetchJson: async () => undefined })).toBe(1)
    expect(world.errors.join("\n")).toContain("not running")
    expect(world.logs).toEqual([])
    expect(
      await authStatusCommand({ ...world.deps, fetchJson: async () => ({ status: 404, body: {} }) })
    ).toBe(1)
    expect(world.errors.join("\n")).toContain("Update the server")
  })
})

describe("default fetch", () => {
  it("uses globalThis.fetch for the device approval flow", async () => {
    const world = makeWorld()
    vi.stubGlobal("fetch", loginScript())
    try {
      expect(await authLoginCommand(world.deps)).toBe(0)
      expect(world.logs.join("\n")).toContain("Test Cloud")
    } finally {
      vi.unstubAllGlobals()
    }
  })
})

describe("authLogoutCommand", () => {
  it("disconnects through the server and leaves unrelated CLI files alone", async () => {
    const world = makeWorld({
      registration: connectedRegistration,
      files: { "/elsewhere/cloud.json": "another server" }
    })
    expect(await authLogoutCommand(world.deps, { port: 54321 })).toBe(0)
    expect(world.httpCalls.at(-1)?.url).toBe("http://127.0.0.1:54321/v1/cloud/disconnect")
    expect(world.files.size).toBe(1)
    expect(world.logs.join("\n")).toContain("Disconnected")
    expect(await authLogoutCommand(world.deps)).toBe(0)
    expect(world.logs.at(-1)).toContain("not connected")
  })

  it("reports a failure to disconnect", async () => {
    const world = makeWorld({ registration: { deviceId: "device-1" } })
    const deps = {
      ...world.deps,
      fetchJson: async (url: string) =>
        url.endsWith("/disconnect") ? undefined : world.deps.fetchJson(url)
    }
    expect(await authLogoutCommand(deps)).toBe(1)
    expect(world.errors.join("\n")).toContain("could not remove")
    expect(await authLogoutCommand(world.deps)).toBe(0)
    expect(world.logs.join("\n")).toContain("Codevisor Cloud")
  })
})

const loginScript = (machinesResponse?: Response) =>
  scriptedFetch({
    "/.well-known/codevisor": [jsonResponse(instanceBody)],
    "/api/auth/device/code": [jsonResponse(grantBody())],
    "/api/auth/device/token": [jsonResponse({ access_token: "session" })],
    "/api/machines": [
      machinesResponse ??
        jsonResponse({ machines: [{ deviceId: "dev-0", name: "Original", online: true }] })
    ]
  })

describe("auth login sync choice", () => {
  it("applies a prompted opt-out through the local server", async () => {
    const world = makeWorld()
    const calls: Array<{ url: string; body?: unknown }> = []
    const deps: CliDeps = {
      ...world.deps,
      fetchJson: (url, init) => {
        if (!url.endsWith("/v1/sync-participation")) return world.deps.fetchJson(url, init)
        calls.push({ url, body: init?.body })
        return Promise.resolve({ status: 200, body: { enabled: false } })
      }
    }
    const code = await authLoginCommand(deps, {
      server: "https://cloud.example",
      fetchImpl: loginScript(),
      promptSyncConfig: () => Promise.resolve(false)
    })
    expect(code).toBe(0)
    expect(calls[0]?.url).toContain("/v1/sync-participation")
    expect(calls[0]?.body).toEqual({ enabled: false })
    expect(world.logs.join("\n")).toContain("Config sync is off")
  })

  it("prefers the explicit flag over the prompt and hints when the server is down", async () => {
    const world = makeWorld()
    let prompted = false
    const code = await authLoginCommand(world.deps, {
      server: "https://cloud.example",
      fetchImpl: loginScript(),
      syncConfig: false,
      promptSyncConfig: () => {
        prompted = true
        return Promise.resolve(true)
      }
    })
    expect(code).toBe(0)
    expect(prompted).toBe(false)
    expect(world.logs.join("\n")).toContain("codevisor sync off")

    const optIn = makeWorld()
    expect(
      await authLoginCommand(optIn.deps, {
        server: "https://cloud.example",
        fetchImpl: loginScript(),
        syncConfig: true
      })
    ).toBe(0)
    expect(optIn.logs.join("\n")).toContain("codevisor sync on")
  })

  it("confirms a prompted opt-in", async () => {
    const world = makeWorld()
    const deps: CliDeps = {
      ...world.deps,
      fetchJson: (url, init) =>
        url.endsWith("/v1/sync-participation")
          ? Promise.resolve({ status: 200, body: { enabled: true } })
          : world.deps.fetchJson(url, init)
    }
    const code = await authLoginCommand(deps, {
      server: "https://cloud.example",
      fetchImpl: loginScript(),
      promptSyncConfig: () => Promise.resolve(true)
    })
    expect(code).toBe(0)
    expect(world.logs.join("\n")).toContain("Config sync is on")
  })
})

describe("auth login fleet awareness", () => {
  it("never prompts the account's first machine and says why", async () => {
    const world = makeWorld()
    let prompted = false
    const code = await authLoginCommand(world.deps, {
      server: "https://cloud.example",
      fetchImpl: loginScript(jsonResponse({ machines: [] })),
      promptSyncConfig: () => {
        prompted = true
        return Promise.resolve(false)
      }
    })
    expect(code).toBe(0)
    expect(prompted).toBe(false)
    expect(world.logs.join("\n")).toContain("first machine on your account")
    expect(world.logs.join("\n")).not.toContain("Config sync is")
  })

  it("shows the existing fleet before asking a joining machine", async () => {
    const world = makeWorld()
    const deps: CliDeps = {
      ...world.deps,
      fetchJson: (url, init) =>
        url.endsWith("/v1/sync-participation")
          ? Promise.resolve({ status: 200, body: { enabled: true } })
          : world.deps.fetchJson(url, init)
    }
    const code = await authLoginCommand(deps, {
      server: "https://cloud.example",
      fetchImpl: loginScript(
        jsonResponse({
          machines: [
            { deviceId: "dev-1", name: "Studio" },
            { deviceId: "dev-2", name: "Laptop" }
          ]
        })
      ),
      promptSyncConfig: () => Promise.resolve(true)
    })
    expect(code).toBe(0)
    expect(world.logs.join("\n")).toContain("already has 2 machines: Studio, Laptop.")
    expect(world.logs.join("\n")).toContain("Config sync is on")
  })

  it("keeps the ask when the machine list is unreachable", async () => {
    const world = makeWorld()
    const deps: CliDeps = {
      ...world.deps,
      fetchJson: (url, init) =>
        url.endsWith("/v1/sync-participation")
          ? Promise.resolve({ status: 200, body: { enabled: false } })
          : world.deps.fetchJson(url, init)
    }
    let prompted = false
    const code = await authLoginCommand(deps, {
      server: "https://cloud.example",
      fetchImpl: loginScript(jsonResponse({ error: "boom" }, 500)),
      promptSyncConfig: () => {
        prompted = true
        return Promise.resolve(false)
      }
    })
    expect(code).toBe(0)
    expect(prompted).toBe(true)
    expect(world.logs.join("\n")).not.toContain("already has")
    expect(world.logs.join("\n")).toContain("Config sync is off")
  })
})
