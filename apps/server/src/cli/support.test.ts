import { describe, expect, it } from "vitest"
import {
  DEFAULT_PORT,
  detectServiceManager,
  logFilePath,
  pidFilePath,
  resolvePort,
  restartCommand,
  startCommand,
  stopCommand
} from "./support.js"
import { makeWorld, unit, systemCat, userCat, health, ok } from "./support-test-support.js"

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
})
