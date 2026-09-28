import { describe, expect, it } from "vitest"

import { setupCommand, type SetupDeps } from "./setup.js"
import { DEFAULT_PORT, type ExecResult } from "./support.js"

interface FakeOptions {
  readonly http?: Record<string, ReadonlyArray<{ status: number; body?: unknown } | undefined>>
  readonly env?: Record<string, string | undefined>
  readonly isInteractive?: boolean
  readonly loginCode?: number
}

interface FakeWorld {
  readonly deps: SetupDeps
  readonly logs: string[]
  readonly errors: string[]
  readonly logins: number[]
}

const failure: ExecResult = { code: 1, stdout: "", stderr: "" }

const makeWorld = (options: FakeOptions = {}): FakeWorld => {
  const logs: string[] = []
  const errors: string[] = []
  const logins: number[] = []
  const httpCounts = new Map<string, number>()

  const deps: SetupDeps = {
    exec: () => Promise.resolve(failure),
    /* v8 ignore next 3 -- setup never runs interactive child processes. */
    execInteractive: () => Promise.resolve(0),
    spawnDetachedServer: () => Promise.resolve(4242),
    fetchJson: (url, init) => {
      const key = `${init?.method ?? "GET"} ${url}`
      const responses = options.http?.[key] ?? [undefined]
      const index = httpCounts.get(key) ?? 0
      httpCounts.set(key, index + 1)
      const response = responses[Math.min(index, responses.length - 1)]
      return Promise.resolve(
        response === undefined ? undefined : { status: response.status, body: response.body }
      )
    },
    readTextFile: () => undefined,
    writeTextFile: () => undefined,
    removeFile: () => undefined,
    processAlive: () => false,
    signal: () => true,
    sleep: () => Promise.resolve(),
    env: options.env ?? {},
    isRoot: false,
    installedVersion: () => undefined,
    dataDir: "/home/user/.codevisor/data",
    logsDir: "/home/user/.codevisor/logs",
    log: (line) => void logs.push(line),
    error: (line) => void errors.push(line),
    isInteractive: options.isInteractive ?? true,
    cloudLogin: (port) => {
      logins.push(port)
      return Promise.resolve(options.loginCode ?? 0)
    }
  }
  return { deps, logs, errors, logins }
}

const health = (port = DEFAULT_PORT) => `GET http://127.0.0.1:${port}/v1/health`
const cloud = (port = DEFAULT_PORT) => `GET http://127.0.0.1:${port}/v1/cloud`
const ok = { status: 200, body: { ok: true } }
const notRegistered = { status: 200, body: { connected: false } }

describe("codevisor setup", () => {
  it("skips under CODEVISOR_NO_SETUP and refuses non-interactive terminals", async () => {
    const skipped = makeWorld({ env: { CODEVISOR_NO_SETUP: "1" } })
    expect(await setupCommand(skipped.deps)).toBe(0)
    expect(skipped.logs[0]).toContain("Skipping setup")
    expect(skipped.logins).toEqual([])

    const nonTty = makeWorld({ isInteractive: false })
    expect(await setupCommand(nonTty.deps)).toBe(1)
    expect(nonTty.errors[0]).toContain("interactive terminal")
    expect(nonTty.logins).toEqual([])
  })

  it("starts the server, then signs the machine into the cloud on its port", async () => {
    const port = 40000
    const world = makeWorld({ http: { [health(port)]: [ok], [cloud(port)]: [notRegistered] } })
    expect(await setupCommand(world.deps, { port })).toBe(0)
    expect(world.logins).toEqual([port])
    expect(world.logs.join("\n")).toContain("Setup complete")
    expect(world.errors).toEqual([])
  })

  it("reports an already-connected machine without signing in again", async () => {
    const world = makeWorld({
      http: {
        [health()]: [ok],
        [cloud()]: [
          {
            status: 200,
            body: { deviceId: "d", serverUrl: "https://cloud.example", state: "connected" }
          }
        ]
      }
    })
    expect(await setupCommand(world.deps)).toBe(0)
    expect(world.logins).toEqual([])
    const output = world.logs.join("\n")
    expect(output).toContain("already connected to your https://cloud.example account")
    expect(output).toContain("codevisor auth status")

    const unnamed = makeWorld({
      http: { [health()]: [ok], [cloud()]: [{ status: 200, body: { deviceId: "d" } }] }
    })
    expect(await setupCommand(unnamed.deps)).toBe(0)
    expect(unnamed.logs.join("\n")).toContain("your Codevisor Cloud account")
  })

  it("fails with a retry hint when the sign-in does not finish", async () => {
    const world = makeWorld({
      http: { [health()]: [ok], [cloud()]: [notRegistered] },
      loginCode: 1
    })
    expect(await setupCommand(world.deps)).toBe(1)
    expect(world.errors.join("\n")).toContain("Retry with: codevisor auth login")
    expect(world.logs.join("\n")).not.toContain("Setup complete")
  })

  it("stops when the server cannot start", async () => {
    // Health never succeeds and the spawned server never comes up.
    const world = makeWorld()
    expect(await setupCommand(world.deps)).toBe(1)
    expect(world.logins).toEqual([])
  })
})
