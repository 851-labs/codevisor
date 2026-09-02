import { describe, expect, it } from "vitest"
import {
  DEFAULT_PORT,
  logsCommand,
  restartCommand,
  statusCommand,
  tokenCommand,
  updateCommand
} from "./support.js"
import { makeWorld, unit, systemCat, userCat, health, ok } from "./support-test-support.js"

describe("codevisor CLI status, token, update, and logs", () => {
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
        [`GET ${base}/v1/update?refresh=1`]: [
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
        [`GET ${base}/v1/update?refresh=1`]: [
          { status: 200, body: { updateAvailable: false, currentVersion: "1.0.0" } }
        ]
      }
    })
    expect(await updateCommand(upToDate.deps)).toBe(0)
    expect(upToDate.logs[0]).toBe("Already up to date (1.0.0)")

    const noVersions = makeWorld({
      http: {
        [`GET ${base}/v1/update?refresh=1`]: [{ status: 200, body: { updateAvailable: false } }]
      }
    })
    expect(await updateCommand(noVersions.deps)).toBe(0)
    expect(noVersions.logs[0]).toBe("Already up to date (unknown version)")

    const declined = makeWorld({
      http: {
        [`GET ${base}/v1/update?refresh=1`]: [{ status: 200, body: { updateAvailable: true } }],
        [`POST ${base}/v1/update/apply`]: [{ status: 200, body: { accepted: false } }]
      }
    })
    expect(await updateCommand(declined.deps)).toBe(1)
    expect(declined.logs[0]).toBe("Updating ? → ?")
    expect(declined.errors[0]).toContain("declined")

    const timedOut = makeWorld({
      http: {
        [`GET ${base}/v1/update?refresh=1`]: [
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

  it("force-checks and applies Alpha updates, accepting the base runtime version", async () => {
    const base = `http://127.0.0.1:${DEFAULT_PORT}`
    const updateURL = `${base}/v1/update?refresh=1&channel=alpha`
    const world = makeWorld({
      http: {
        [`GET ${updateURL}`]: [
          {
            status: 200,
            body: {
              updateAvailable: true,
              currentVersion: "1.2.0",
              latestVersion: "1.2.0-alpha.42"
            }
          },
          {
            status: 200,
            body: {
              updateAvailable: false,
              currentVersion: "1.2.0",
              latestVersion: "1.2.0-alpha.42"
            }
          }
        ],
        [`GET ${base}/v1/health`]: [
          { status: 200, body: { bootId: "old" } },
          { status: 200, body: { bootId: "new" } }
        ],
        [`POST ${base}/v1/update/apply?channel=alpha`]: [{ status: 202, body: { accepted: true } }],
        [`GET ${base}/v1/info`]: [undefined, { status: 200, body: { version: "1.2.0" } }]
      }
    })

    expect(await updateCommand(world.deps, { alpha: true })).toBe(0)
    expect(world.logs.at(-1)).toBe("Codevisor server updated to 1.2.0-alpha.42")
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
