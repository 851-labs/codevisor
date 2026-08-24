import { describe, expect, it } from "vitest"
import type { CliDeps, ExecResult } from "./support.js"
import { applySyncParticipation, syncCommand } from "./sync.js"

const failure: ExecResult = { code: 1, stdout: "", stderr: "" }

interface FetchCall {
  readonly url: string
  readonly init?: { readonly method?: string; readonly body?: unknown; readonly timeoutMs?: number }
}

const makeWorld = (
  responses: Array<{ readonly status: number; readonly body: unknown } | undefined>
): { deps: CliDeps; logs: string[]; errors: string[]; calls: FetchCall[] } => {
  const logs: string[] = []
  const errors: string[] = []
  const calls: FetchCall[] = []
  const deps: CliDeps = {
    exec: () => Promise.resolve(failure),
    execInteractive: () => Promise.resolve(0),
    spawnDetachedServer: () => Promise.resolve(4242),
    fetchJson: (url, init) => {
      calls.push(init === undefined ? { url } : { url, init })
      return Promise.resolve(responses.shift())
    },
    readTextFile: () => undefined,
    writeTextFile: () => {},
    removeFile: () => {},
    processAlive: () => false,
    signal: () => true,
    sleep: () => Promise.resolve(),
    env: {},
    isRoot: false,
    installedVersion: () => undefined,
    dataDir: "/home/user/.codevisor/data",
    logsDir: "/home/user/.codevisor/logs",
    log: (line) => void logs.push(line),
    error: (line) => void errors.push(line)
  }
  return { deps, logs, errors, calls }
}

describe("codevisor sync", () => {
  it("reports the current participation state", async () => {
    const on = makeWorld([{ status: 200, body: { enabled: true } }])
    expect(await syncCommand(on.deps)).toBe(0)
    expect(on.logs.join("\n")).toContain("Config sync is on")
    expect(on.calls[0]?.url).toContain("/v1/sync-participation")

    const off = makeWorld([{ status: 200, body: { enabled: false } }])
    expect(await syncCommand(off.deps)).toBe(0)
    expect(off.logs.join("\n")).toContain("Config sync is off")
  })

  it("sets participation on and off via the local server", async () => {
    const on = makeWorld([{ status: 200, body: { enabled: true } }])
    expect(await syncCommand(on.deps, { enabled: true })).toBe(0)
    expect(on.calls[0]?.init?.method).toBe("PUT")
    expect(on.calls[0]?.init?.body).toEqual({ enabled: true })
    expect(on.logs.join("\n")).toContain("Config sync is now on")

    const off = makeWorld([{ status: 200, body: { enabled: false } }])
    expect(await syncCommand(off.deps, { enabled: false, port: 5050 })).toBe(0)
    expect(off.calls[0]?.url).toContain(":5050/")
    expect(off.logs.join("\n")).toContain("Config sync is now off")
  })

  it("fails loudly when the server is unreachable or refuses", async () => {
    const unreachable = makeWorld([undefined])
    expect(await syncCommand(unreachable.deps)).toBe(1)
    expect(unreachable.errors.join("\n")).toContain("codevisor start")

    const refused = makeWorld([{ status: 500, body: {} }])
    expect(await syncCommand(refused.deps)).toBe(1)

    const setFails = makeWorld([undefined])
    expect(await syncCommand(setFails.deps, { enabled: false })).toBe(1)
    expect(setFails.errors.join("\n")).toContain("codevisor start")
  })

  it("applySyncParticipation reports success only on a 200", async () => {
    const rejected = makeWorld([{ status: 403, body: {} }])
    expect(await applySyncParticipation(rejected.deps, true)).toBe(false)
  })
})
