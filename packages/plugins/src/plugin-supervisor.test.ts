import { createServer, type Server } from "node:http"
import { describe, expect, it } from "vitest"
import {
  makePluginSupervisor,
  type PluginTerminalProcess,
  type RegisterPluginTerminal
} from "./plugin-supervisor.js"
import { PluginsError } from "./plugins-error.js"
import { cleanups, fakeSpawn, makeDataDir, plugin } from "./test-support.js"

describe("makePluginSupervisor", () => {
  it("starts lazily, reuses the running process, and reports state", async () => {
    const spawn = fakeSpawn()
    const supervisor = makePluginSupervisor({
      dataDir: makeDataDir(),
      spawnShell: spawn.spawnShell
    })
    const target = plugin()
    expect(supervisor.state("owner.example")).toBe("stopped")
    const port = await supervisor.ensureRunning(target)
    expect(port).toBeGreaterThan(0)
    expect(supervisor.state("owner.example")).toBe("running")
    expect(await supervisor.ensureRunning(target)).toBe(port)
    expect(spawn.spawnCount()).toBe(1)
    supervisor.closeAll()
    expect(supervisor.state("owner.example")).toBe("stopped")
  })

  it("shares one start attempt across concurrent callers", async () => {
    const spawn = fakeSpawn()
    const supervisor = makePluginSupervisor({
      dataDir: makeDataDir(),
      spawnShell: spawn.spawnShell
    })
    const target = plugin()
    const [first, second] = await Promise.all([
      supervisor.ensureRunning(target),
      supervisor.ensureRunning(target)
    ])
    expect(first).toBe(second)
    expect(spawn.spawnCount()).toBe(1)
  })

  it("fails with a typed error when the plugin never listens", async () => {
    const spawn = fakeSpawn({ listen: false })
    const supervisor = makePluginSupervisor({
      dataDir: makeDataDir(),
      readyTimeoutMs: 400,
      spawnShell: spawn.spawnShell
    })
    await expect(supervisor.ensureRunning(plugin())).rejects.toThrow(/did not start listening/)
    expect(supervisor.state("owner.example")).toBe("failed")
  })

  it("fails fast when the process exits before it is ready", async () => {
    const spawn = fakeSpawn({ listen: false })
    const supervisor = makePluginSupervisor({
      dataDir: makeDataDir(),
      readyTimeoutMs: 5_000,
      spawnShell: (command, options) => {
        const handle = spawn.spawnShell(command, options)
        setTimeout(() => spawn.simulateExit("exited with code 3\nboom"), 50)
        return handle
      }
    })
    try {
      await supervisor.ensureRunning(plugin())
      expect.unreachable("start should have failed")
    } catch (cause) {
      expect(cause).toBeInstanceOf(PluginsError)
      expect((cause as PluginsError).message).toContain("exited with code 3")
    }
  })

  it("marks the runtime stopped when a running plugin exits", async () => {
    const spawn = fakeSpawn()
    const logs: Array<string> = []
    const supervisor = makePluginSupervisor({
      dataDir: makeDataDir(),
      log: (message) => logs.push(message),
      spawnShell: spawn.spawnShell
    })
    await supervisor.ensureRunning(plugin())
    spawn.simulateExit("terminated by SIGTERM")
    expect(supervisor.state("owner.example")).toBe("stopped")
    expect(logs.some((line) => line.includes("terminated by SIGTERM"))).toBe(true)
  })

  it("ignores exits from superseded processes", async () => {
    const spawn = fakeSpawn()
    const supervisor = makePluginSupervisor({
      dataDir: makeDataDir(),
      spawnShell: spawn.spawnShell
    })
    const target = plugin()
    await supervisor.ensureRunning(target)
    supervisor.stop("owner.example")
    // The old process's exit callback fires after stop() already cleared it.
    spawn.simulateExit("exited with code 0")
    expect(supervisor.state("owner.example")).toBe("stopped")
  })

  it("stop is a no-op for unknown plugins", () => {
    const supervisor = makePluginSupervisor({ dataDir: makeDataDir() })
    supervisor.stop("owner.unknown")
    expect(supervisor.state("owner.unknown")).toBe("stopped")
  })

  it("launches real processes through the login shell by default", async () => {
    const frames: Array<string> = []
    const supervisor = makePluginSupervisor({
      dataDir: makeDataDir(),
      registerExternalTerminal: (terminalConfig, _process) => {
        expect(terminalConfig.sessionId).toBe("plugin:owner.example")
        return {
          exit: () => frames.push("[exit]"),
          output: (data) => frames.push(data),
          terminalId: "terminal-1"
        }
      },
      resolveEnv: async () => ({ ...process.env })
    })
    const server = `const http = require("http"); console.log("plugin out"); console.error("plugin boot"); http.createServer((q, s) => s.end("ok")).listen(process.env.PORT, "127.0.0.1")`
    const target = plugin({ run: { command: `"${process.execPath}" -e '${server}'` } })
    cleanups.push(() => supervisor.closeAll())
    const port = await supervisor.ensureRunning(target)
    const response = await fetch(`http://127.0.0.1:${port}/`)
    expect(await response.text()).toBe("ok")
    // Both stdio streams ride the observability terminal, after the command
    // header line.
    expect(frames[0]).toContain(target.manifest.run.command)
    await expect.poll(() => frames.join("")).toContain("plugin out")
    await expect.poll(() => frames.join("")).toContain("plugin boot")
  })

  it("streams fake process output through the terminal seam and closes it on exit", async () => {
    const frames: Array<string> = []
    let recordedProcess: PluginTerminalProcess | undefined
    const registerExternalTerminal: RegisterPluginTerminal = (_terminalConfig, handle) => {
      recordedProcess = handle
      return {
        exit: () => frames.push("[exit]"),
        output: (data) => frames.push(data),
        terminalId: "terminal-1"
      }
    }
    let server: Server | undefined
    cleanups.push(() => server?.close())
    const exitListeners: Array<(message: string) => void> = []
    const outputListeners: Array<(data: string) => void> = []
    const supervisor = makePluginSupervisor({
      dataDir: makeDataDir(),
      registerExternalTerminal,
      spawnShell: (_command, options) => {
        server = createServer((_request, response) => response.end("ok"))
        server.listen(Number(options.env["PORT"]), "127.0.0.1")
        return {
          kill: () => server?.close(),
          onExit: (listener) => exitListeners.push(listener),
          onOutput: (listener) => outputListeners.push(listener),
          pid: 4242
        }
      }
    })
    await supervisor.ensureRunning(plugin())
    for (const listener of outputListeners) {
      listener("hello from plugin\n")
    }
    server?.close()
    for (const listener of exitListeners) {
      listener("exited with code 0")
    }
    expect(frames[0]).toBe("$ run-me\r\n")
    expect(frames).toContain("hello from plugin\n")
    expect(frames.at(-1)).toBe("[exit]")
    // The terminal-facing process handle proxies onto the child; exercise its
    // full surface (write/resize are deliberate no-ops for external procs).
    recordedProcess?.write("ignored")
    recordedProcess?.resize(80, 24)
    recordedProcess?.kill()
  })

  it("registers a terminal even when the spawner cannot stream output", async () => {
    const frames: Array<string> = []
    const spawn = fakeSpawn()
    const supervisor = makePluginSupervisor({
      dataDir: makeDataDir(),
      registerExternalTerminal: (_terminalConfig, _process) => ({
        exit: () => frames.push("[exit]"),
        output: (data) => frames.push(data),
        terminalId: "terminal-1"
      }),
      spawnShell: spawn.spawnShell
    })
    await supervisor.ensureRunning(plugin())
    expect(frames).toEqual(["$ run-me\r\n"])
    spawn.simulateExit("terminated by SIGTERM")
    expect(frames).toEqual(["$ run-me\r\n", "[exit]"])
  })

  it("surfaces stderr from real processes that die before listening", async () => {
    const supervisor = makePluginSupervisor({ dataDir: makeDataDir() })
    const target = plugin({
      run: { command: `"${process.execPath}" -e 'console.error("boom"); process.exit(3)'` }
    })
    try {
      await supervisor.ensureRunning(target)
      expect.unreachable("start should have failed")
    } catch (cause) {
      expect((cause as PluginsError).message).toContain("exited with code 3")
      expect((cause as PluginsError).message).toContain("boom")
    }
  })

  it("reports launch failures when the shell itself cannot start", async () => {
    const previousShell = process.env["SHELL"]
    process.env["SHELL"] = "/nonexistent-codevisor-shell"
    try {
      const supervisor = makePluginSupervisor({ dataDir: makeDataDir() })
      await expect(supervisor.ensureRunning(plugin())).rejects.toThrow(/Failed to launch|exited/)
    } finally {
      if (previousShell === undefined) {
        delete process.env["SHELL"]
      } else {
        process.env["SHELL"] = previousShell
      }
    }
  })

  it("kills real process groups on stop", async () => {
    const supervisor = makePluginSupervisor({ dataDir: makeDataDir() })
    const server = `const http = require("http"); http.createServer((q, s) => s.end("ok")).listen(process.env.PORT, "127.0.0.1")`
    const target = plugin({ run: { command: `"${process.execPath}" -e '${server}'` } })
    const port = await supervisor.ensureRunning(target)
    supervisor.stop("owner.example")
    // The listener disappears once the process group dies.
    await expect
      .poll(async () => {
        try {
          await fetch(`http://127.0.0.1:${port}/`)
          return "up"
        } catch {
          return "down"
        }
      })
      .toBe("down")
  })
})
