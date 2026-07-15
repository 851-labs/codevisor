import { describe, expect, it } from "vitest"
import {
  DEFAULT_PORT,
  detectServiceManager,
  logFilePath,
  logsCommand,
  pidFilePath,
  resolvePort,
  restartCommand,
  startCommand,
  statusCommand,
  stopCommand,
  tokenCommand,
  updateCommand,
  type CliDeps,
  type ExecResult
} from "./support.js"

interface FakeWorld {
  readonly deps: CliDeps
  readonly logs: string[]
  readonly errors: string[]
  readonly execCalls: Array<string>
  readonly interactiveCalls: Array<string>
  readonly spawned: Array<{ args: ReadonlyArray<string>; logPath: string }>
  readonly files: Map<string, string>
  readonly signals: Array<{ pid: number; signal: string }>
}

interface FakeOptions {
  /// Keyed by "command arg arg…" → result (or a queue of results).
  readonly exec?: Record<string, ExecResult>
  /// Keyed by "METHOD url" → response bodies returned in order (last repeats).
  readonly http?: Record<string, ReadonlyArray<{ status: number; body?: unknown } | undefined>>
  readonly files?: Record<string, string>
  readonly alivePids?: ReadonlyArray<number>
  readonly killStopsPid?: boolean
  readonly isRoot?: boolean
  readonly env?: Record<string, string | undefined>
  readonly installedVersion?: string
  readonly interactiveExit?: number
  readonly spawnPid?: number
}

const failure: ExecResult = { code: 1, stdout: "", stderr: "" }

const makeWorld = (options: FakeOptions = {}): FakeWorld => {
  const logs: string[] = []
  const errors: string[] = []
  const execCalls: string[] = []
  const interactiveCalls: string[] = []
  const spawned: Array<{ args: ReadonlyArray<string>; logPath: string }> = []
  const files = new Map<string, string>(Object.entries(options.files ?? {}))
  const signals: Array<{ pid: number; signal: string }> = []
  const alive = new Set(options.alivePids ?? [])
  const httpCounts = new Map<string, number>()

  const deps: CliDeps = {
    exec: (command, args) => {
      const key = [command, ...args].join(" ")
      execCalls.push(key)
      return Promise.resolve(options.exec?.[key] ?? failure)
    },
    execInteractive: (command, args) => {
      interactiveCalls.push([command, ...args].join(" "))
      return Promise.resolve(options.interactiveExit ?? 0)
    },
    spawnDetachedServer: (args, logPath) => {
      spawned.push({ args, logPath })
      return Promise.resolve(options.spawnPid ?? 4242)
    },
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
    readTextFile: (path) => files.get(path),
    writeTextFile: (path, contents) => void files.set(path, contents),
    removeFile: (path) => void files.delete(path),
    processAlive: (pid) => alive.has(pid),
    signal: (pid, signal) => {
      signals.push({ pid, signal })
      if (options.killStopsPid !== false) alive.delete(pid)
      return true
    },
    sleep: () => Promise.resolve(),
    env: options.env ?? {},
    isRoot: options.isRoot ?? false,
    installedVersion: () => options.installedVersion,
    dataDir: "/home/user/.codevisor/data",
    logsDir: "/home/user/.codevisor/logs",
    log: (line) => void logs.push(line),
    error: (line) => void errors.push(line)
  }
  return { deps, logs, errors, execCalls, interactiveCalls, spawned, files, signals }
}

const unit = (port: number): ExecResult => ({
  code: 0,
  stdout: `[Service]\nExecStart=/opt/codevisor/bin/codevisor-server serve --host 0.0.0.0 --port ${port} --auth token\n`,
  stderr: ""
})

const systemCat = "systemctl cat codevisor-server.service"
const userCat = "systemctl --user cat codevisor-server.service"
const health = (port: number): string => `GET http://127.0.0.1:${port}/v1/health`
const ok = { status: 200, body: { ok: true } }

describe("codevisor CLI support", () => {
  it("detects system units, user units, and the pidfile fallback", async () => {
    const system = makeWorld({ exec: { [systemCat]: unit(50000) } })
    expect(await detectServiceManager(system.deps)).toMatchObject({ kind: "systemd-system" })

    const user = makeWorld({ exec: { [userCat]: unit(50001) } })
    expect(await detectServiceManager(user.deps)).toMatchObject({ kind: "systemd-user" })

    const none = makeWorld()
    expect(await detectServiceManager(none.deps)).toEqual({ kind: "pidfile" })
  })

  it("resolves the port from flag, env, unit, then default", async () => {
    const world = makeWorld({ exec: { [systemCat]: unit(50123) } })
    expect(await resolvePort(world.deps, 40000)).toBe(40000)

    const env = makeWorld({ env: { CODEVISOR_PORT: "40500" } })
    expect(await resolvePort(env.deps)).toBe(40500)

    const badEnv = makeWorld({
      env: { CODEVISOR_PORT: "not-a-port" },
      exec: { [systemCat]: unit(50123) }
    })
    expect(await resolvePort(badEnv.deps)).toBe(50123)

    const preDetected = makeWorld()
    expect(
      await resolvePort(preDetected.deps, undefined, {
        kind: "systemd-user",
        unitText: "--port 51000"
      })
    ).toBe(51000)

    const noUnitPort = makeWorld({
      exec: { [systemCat]: { code: 0, stdout: "ExecStart=serve", stderr: "" } }
    })
    expect(await resolvePort(noUnitPort.deps)).toBe(DEFAULT_PORT)

    expect(pidFilePath(world.deps)).toBe("/home/user/.codevisor/data/server.pid")
    expect(logFilePath(world.deps)).toBe("/home/user/.codevisor/logs/server.log")
  })

  it("starts via systemctl and waits for health", async () => {
    const world = makeWorld({
      exec: {
        [systemCat]: unit(50000),
        "systemctl start codevisor-server.service": { code: 0, stdout: "", stderr: "" }
      },
      http: { [health(50000)]: [undefined, ok] }
    })
    expect(await startCommand(world.deps)).toBe(0)
    expect(world.logs.at(-1)).toContain("running on port 50000")
  })

  it("reports systemctl failures with a sudo hint for system units", async () => {
    const world = makeWorld({
      exec: {
        [systemCat]: unit(50000),
        "systemctl start codevisor-server.service": { code: 4, stdout: "", stderr: "access denied" }
      }
    })
    expect(await startCommand(world.deps)).toBe(4)
    expect(world.errors).toContain("access denied")
    expect(world.errors.some((line) => line.includes("sudo codevisor start"))).toBe(true)

    const rootWorld = makeWorld({
      isRoot: true,
      exec: {
        [systemCat]: unit(50000),
        "systemctl start codevisor-server.service": { code: 4, stdout: "", stderr: "" }
      }
    })
    expect(await startCommand(rootWorld.deps)).toBe(4)
    expect(rootWorld.errors).toContain("systemctl start failed")
    expect(rootWorld.errors.some((line) => line.includes("sudo"))).toBe(false)
  })

  it("fails when a systemd start never becomes healthy", async () => {
    const world = makeWorld({
      exec: {
        [userCat]: unit(50001),
        "systemctl --user start codevisor-server.service": { code: 0, stdout: "", stderr: "" }
      }
    })
    expect(await startCommand(world.deps)).toBe(1)
    expect(world.errors.some((line) => line.includes("codevisor logs"))).toBe(true)
  })

  it("starts a detached server with a pidfile when there is no unit", async () => {
    const world = makeWorld({
      http: { [health(DEFAULT_PORT)]: [undefined, ok] },
      spawnPid: 777
    })
    expect(await startCommand(world.deps)).toBe(0)
    expect(world.spawned[0]?.args).toEqual([
      "serve",
      "--host",
      "0.0.0.0",
      "--port",
      String(DEFAULT_PORT),
      "--auth",
      "token",
      "--db",
      "/home/user/.codevisor/data/codevisor-server.sqlite"
    ])
    expect(world.files.get("/home/user/.codevisor/data/server.pid")).toBe("777\n")
    expect(world.logs.at(-1)).toContain("pid 777")
  })

  it("does not double-start: healthy server and half-dead process are surfaced", async () => {
    const healthy = makeWorld({ http: { [health(DEFAULT_PORT)]: [ok] } })
    expect(await startCommand(healthy.deps)).toBe(0)
    expect(healthy.logs.at(-1)).toContain("already running")
    expect(healthy.spawned).toHaveLength(0)

    const halfDead = makeWorld({
      files: { "/home/user/.codevisor/data/server.pid": "900\n" },
      alivePids: [900]
    })
    expect(await startCommand(halfDead.deps)).toBe(1)
    expect(halfDead.errors.some((line) => line.includes("codevisor stop"))).toBe(true)
  })

  it("fails when the spawned server never becomes healthy", async () => {
    const world = makeWorld({ files: { "/home/user/.codevisor/data/server.pid": "garbage" } })
    expect(await startCommand(world.deps)).toBe(1)
    expect(world.errors.some((line) => line.includes("server.log"))).toBe(true)
  })

  it("stops via systemctl for unit installs", async () => {
    const world = makeWorld({
      exec: {
        [systemCat]: unit(50000),
        "systemctl stop codevisor-server.service": { code: 0, stdout: "", stderr: "" }
      }
    })
    expect(await stopCommand(world.deps)).toBe(0)
  })

  it("stops a pidfile server with SIGTERM and clears the pidfile", async () => {
    const world = makeWorld({
      files: { "/home/user/.codevisor/data/server.pid": "555\n" },
      alivePids: [555]
    })
    expect(await stopCommand(world.deps)).toBe(0)
    expect(world.signals).toEqual([{ pid: 555, signal: "SIGTERM" }])
    expect(world.files.has("/home/user/.codevisor/data/server.pid")).toBe(false)
  })

  it("reports a process that survives SIGTERM", async () => {
    const world = makeWorld({
      files: { "/home/user/.codevisor/data/server.pid": "556\n" },
      alivePids: [556],
      killStopsPid: false
    })
    expect(await stopCommand(world.deps)).toBe(1)
    expect(world.errors[0]).toContain("did not exit")
  })

  it("falls back to POST /v1/shutdown for unmanaged healthy servers", async () => {
    const world = makeWorld({
      http: {
        [health(DEFAULT_PORT)]: [ok, ok, undefined],
        [`POST http://127.0.0.1:${DEFAULT_PORT}/v1/shutdown`]: [{ status: 202, body: { ok: true } }]
      }
    })
    expect(await stopCommand(world.deps)).toBe(0)
    expect(world.logs.at(-1)).toBe("Codevisor server stopped")

    const stubborn = makeWorld({ http: { [health(DEFAULT_PORT)]: [ok] } })
    expect(await stopCommand(stubborn.deps)).toBe(1)
    expect(stubborn.errors[0]).toContain("still answering")

    const notRunning = makeWorld()
    expect(await stopCommand(notRunning.deps)).toBe(0)
    expect(notRunning.logs.at(-1)).toBe("Codevisor server is not running")
  })

  it("restarts via systemctl and reports health", async () => {
    const world = makeWorld({
      exec: {
        [systemCat]: unit(50000),
        "systemctl restart codevisor-server.service": { code: 0, stdout: "", stderr: "" }
      },
      http: { [health(50000)]: [ok] }
    })
    expect(await restartCommand(world.deps)).toBe(0)

    const failing = makeWorld({
      exec: {
        [systemCat]: unit(50000),
        "systemctl restart codevisor-server.service": { code: 5, stdout: "", stderr: "boom" }
      }
    })
    expect(await restartCommand(failing.deps)).toBe(5)

    const unhealthy = makeWorld({
      exec: {
        [systemCat]: unit(50000),
        "systemctl restart codevisor-server.service": { code: 0, stdout: "", stderr: "" }
      }
    })
    expect(await restartCommand(unhealthy.deps)).toBe(1)
  })

  it("restarts pidfile servers by stopping then starting", async () => {
    const world = makeWorld({
      files: { "/home/user/.codevisor/data/server.pid": "600\n" },
      alivePids: [600],
      http: { [health(DEFAULT_PORT)]: [undefined, ok] }
    })
    expect(await restartCommand(world.deps)).toBe(0)
    expect(world.signals[0]?.pid).toBe(600)
    expect(world.spawned).toHaveLength(1)

    const stuckStop = makeWorld({
      files: { "/home/user/.codevisor/data/server.pid": "601\n" },
      alivePids: [601],
      killStopsPid: false
    })
    expect(await restartCommand(stuckStop.deps)).toBe(1)
    expect(stuckStop.spawned).toHaveLength(0)
  })

  it("reports status for a stopped server", async () => {
    const world = makeWorld({ installedVersion: "1.2.3" })
    expect(await statusCommand(world.deps)).toBe(1)
    expect(world.logs[0]).toContain("not running")
    expect(world.logs[1]).toBe("Installed version: 1.2.3")

    const noVersion = makeWorld()
    expect(await statusCommand(noVersion.deps)).toBe(1)
    expect(noVersion.logs.some((line) => line.includes("Installed version"))).toBe(false)

    const json = makeWorld({ installedVersion: "1.2.3" })
    expect(await statusCommand(json.deps, { json: true })).toBe(1)
    expect(JSON.parse(json.logs[0] ?? "")).toEqual({
      running: false,
      port: DEFAULT_PORT,
      installedVersion: "1.2.3"
    })

    const jsonNoVersion = makeWorld()
    expect(await statusCommand(jsonNoVersion.deps, { json: true })).toBe(1)
    expect(JSON.parse(jsonNoVersion.logs[0] ?? "")).toMatchObject({ installedVersion: null })
  })

  it("reports status and harness readiness for a running server", async () => {
    const info = {
      status: 200,
      body: {
        id: "local",
        name: "Build Box",
        version: "1.2.3",
        machineId: "machine-1",
        platform: "linux",
        arch: "x64",
        hostname: "build-box"
      }
    }
    const harnesses = {
      status: 200,
      body: [
        {
          id: "claude-code",
          readiness: { state: "ready", version: "2.1.5", path: "/usr/local/bin/claude" }
        },
        { id: "codex", readiness: { state: "unavailable", detail: "CLI not found on PATH" } },
        { id: "broken" },
        { notAnId: true },
        "garbage"
      ]
    }
    const world = makeWorld({
      http: {
        [`GET http://127.0.0.1:${DEFAULT_PORT}/v1/info`]: [info],
        [`GET http://127.0.0.1:${DEFAULT_PORT}/v1/harnesses`]: [harnesses]
      }
    })
    expect(await statusCommand(world.deps)).toBe(0)
    expect(world.logs[0]).toContain("1.2.3 is running on port")
    expect(
      world.logs.some((line) => line.includes("claude-code: ready 2.1.5 (/usr/local/bin/claude)"))
    ).toBe(true)
    expect(world.logs.some((line) => line.includes("codex: unavailable — CLI not found"))).toBe(
      true
    )
    expect(world.logs.some((line) => line.includes("broken: unknown"))).toBe(true)

    const json = makeWorld({
      http: {
        [`GET http://127.0.0.1:${DEFAULT_PORT}/v1/info`]: [info],
        [`GET http://127.0.0.1:${DEFAULT_PORT}/v1/harnesses`]: [{ status: 200, body: "not-a-list" }]
      }
    })
    expect(await statusCommand(json.deps, { json: true })).toBe(0)
    expect(JSON.parse(json.logs[0] ?? "")).toMatchObject({
      running: true,
      version: "1.2.3",
      machineId: "machine-1",
      harnesses: []
    })
  })

  it("prints status without a harness section when none are reported", async () => {
    const info = { status: 200, body: { id: "local", name: "Box", version: "1.0.0" } }
    const world = makeWorld({
      http: { [`GET http://127.0.0.1:${DEFAULT_PORT}/v1/info`]: [info] }
    })
    expect(await statusCommand(world.deps)).toBe(0)
    expect(world.logs.some((line) => line.includes("harnesses:"))).toBe(false)
    expect(world.logs.some((line) => line.includes("unknown"))).toBe(true)
  })

  it("prints the stable connection token and rotates on demand", async () => {
    const world = makeWorld({
      http: {
        [`GET http://127.0.0.1:${DEFAULT_PORT}/v1/auth/connection-token`]: [
          { status: 200, body: { token: "hm_stable" } }
        ]
      }
    })
    expect(await tokenCommand(world.deps)).toBe(0)
    expect(world.logs).toEqual(["hm_stable"])

    const rotated = makeWorld({
      http: {
        [`POST http://127.0.0.1:${DEFAULT_PORT}/v1/auth/connection-token/rotate`]: [
          { status: 201, body: { token: "hm_rotated" } }
        ]
      }
    })
    expect(await tokenCommand(rotated.deps, { rotate: true })).toBe(0)
    expect(rotated.logs).toEqual(["hm_rotated"])

    const down = makeWorld()
    expect(await tokenCommand(down.deps)).toBe(1)
    expect(down.errors[0]).toContain("codevisor start")
  })

  it("updates a running server and waits for the new version", async () => {
    const base = `http://127.0.0.1:${DEFAULT_PORT}`
    const world = makeWorld({
      http: {
        [`GET ${base}/v1/update`]: [
          {
            status: 200,
            body: { updateAvailable: true, currentVersion: "1.0.0", latestVersion: "1.1.0" }
          }
        ],
        [`POST ${base}/v1/update/apply`]: [{ status: 202, body: { accepted: true } }],
        [`GET ${base}/v1/info`]: [
          undefined,
          { status: 200, body: { version: "1.0.0" } },
          { status: 200, body: { version: "1.1.0" } }
        ]
      }
    })
    expect(await updateCommand(world.deps)).toBe(0)
    expect(world.logs.at(-1)).toBe("Codevisor server updated to 1.1.0")
  })

  it("covers update edge cases: down, up to date, declined, timeout", async () => {
    const base = `http://127.0.0.1:${DEFAULT_PORT}`
    const down = makeWorld()
    expect(await updateCommand(down.deps)).toBe(1)
    expect(down.errors.some((line) => line.includes("install script"))).toBe(true)

    const upToDate = makeWorld({
      http: {
        [`GET ${base}/v1/update`]: [
          { status: 200, body: { updateAvailable: false, currentVersion: "1.0.0" } }
        ]
      }
    })
    expect(await updateCommand(upToDate.deps)).toBe(0)
    expect(upToDate.logs[0]).toBe("Already up to date (1.0.0)")

    const noVersions = makeWorld({
      http: { [`GET ${base}/v1/update`]: [{ status: 200, body: { updateAvailable: false } }] }
    })
    expect(await updateCommand(noVersions.deps)).toBe(0)
    expect(noVersions.logs[0]).toBe("Already up to date (unknown version)")

    const declined = makeWorld({
      http: {
        [`GET ${base}/v1/update`]: [{ status: 200, body: { updateAvailable: true } }],
        [`POST ${base}/v1/update/apply`]: [{ status: 200, body: { accepted: false } }]
      }
    })
    expect(await updateCommand(declined.deps)).toBe(1)
    expect(declined.logs[0]).toBe("Updating ? → ?")
    expect(declined.errors[0]).toContain("declined")

    const timedOut = makeWorld({
      http: {
        [`GET ${base}/v1/update`]: [
          {
            status: 200,
            body: { updateAvailable: true, currentVersion: "1.0.0", latestVersion: "1.1.0" }
          }
        ],
        [`POST ${base}/v1/update/apply`]: [{ status: 202, body: { accepted: true } }],
        [`GET ${base}/v1/info`]: [{ status: 200, body: { version: "1.0.0" } }]
      }
    })
    expect(await updateCommand(timedOut.deps)).toBe(1)
    expect(timedOut.errors[0]).toContain("Timed out")
  })

  it("streams logs from journalctl for unit installs", async () => {
    const system = makeWorld({ exec: { [systemCat]: unit(50000) } })
    expect(await logsCommand(system.deps)).toBe(0)
    expect(system.interactiveCalls[0]).toBe("journalctl -u codevisor-server.service -n 100")

    const user = makeWorld({ exec: { [userCat]: unit(50001) } })
    expect(await logsCommand(user.deps, { follow: true })).toBe(0)
    expect(user.interactiveCalls[0]).toBe("journalctl --user -u codevisor-server.service -n 100 -f")
  })

  it("tails the log file for pidfile installs", async () => {
    const world = makeWorld({ files: { "/home/user/.codevisor/logs/server.log": "line\n" } })
    expect(await logsCommand(world.deps, { follow: true })).toBe(0)
    expect(world.interactiveCalls[0]).toBe("tail -n 100 -f /home/user/.codevisor/logs/server.log")

    const noFollow = makeWorld({ files: { "/home/user/.codevisor/logs/server.log": "line\n" } })
    expect(await logsCommand(noFollow.deps)).toBe(0)
    expect(noFollow.interactiveCalls[0]).toBe("tail -n 100 /home/user/.codevisor/logs/server.log")

    const missing = makeWorld()
    expect(await logsCommand(missing.deps)).toBe(1)
    expect(missing.errors[0]).toContain("No log file")
  })
})
