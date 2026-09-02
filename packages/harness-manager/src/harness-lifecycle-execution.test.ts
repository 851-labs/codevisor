import { harnessCatalog } from "@codevisor/agent-runtime"
import type { AgentRuntimeService, HarnessDefinition } from "@codevisor/agent-runtime"
import { Effect } from "effect"
import { makeHarnessLifecycleManager } from "./harness-lifecycle.js"
import type { FetchLike } from "@codevisor/updater"
import { afterEach, describe, expect, it } from "vitest"
import {
  cleanupLifecycleTests,
  run,
  makeDb,
  harness,
  agentsStub,
  jsonResponse,
  makeBinDir,
  fakeTerminal,
  fakeSpawner,
  installableDefinition,
  flush
} from "./harness-lifecycle-test-support.js"

afterEach(cleanupLifecycleTests)

describe("harness lifecycle install/update execution", () => {
  it("resolves install methods with availability and preference", async () => {
    const db = await makeDb()
    // Only npm exists on this PATH → npm is recommended despite brew ranking
    // higher in the preference order.
    const bin = makeBinDir(["npm"])
    const lifecycle = makeHarnessLifecycleManager({
      agents: agentsStub([installableDefinition], []),
      db,
      resolveEnv: async () => ({ PATH: bin })
    })
    const methods = await lifecycle.installMethods("fake-cli")
    expect(methods).toEqual([
      {
        available: false,
        command: "brew install fake-cli",
        id: "brew",
        kind: "brew",
        label: "Homebrew",
        recommended: false
      },
      {
        available: true,
        command: "npm install -g fake-cli",
        id: "npm",
        kind: "npm",
        label: "npm",
        recommended: true
      }
    ])
  })

  it("installs via the recommended method, streams output, and settles to idle", async () => {
    const db = await makeDb()
    const bin = makeBinDir(["brew", "npm"])
    const refreshes: Array<number> = []
    const agents = {
      catalog: [installableDefinition],
      discoverHarnesses: Effect.succeed([]),
      refreshEnvironment: Effect.sync(() => {
        refreshes.push(1)
      })
    } as unknown as AgentRuntimeService
    const { outputs, terminal } = fakeTerminal()
    const { processes, spawnShell, spawns } = fakeSpawner()
    const events: Array<{ payload: { lifecycle?: { phase?: string } } }> = []
    const lifecycle = makeHarnessLifecycleManager({
      agents,
      db,
      fetchImpl: async () => ({
        json: async () => ({}),
        ok: false,
        status: 404,
        text: async () => ""
      }),
      resolveEnv: async () => ({ PATH: bin }),
      spawnShell,
      terminal
    })
    lifecycle.subscribe((event) => events.push(event as never))

    const { terminalId } = await lifecycle.beginInstall("fake-cli")
    expect(terminalId).toBe("terminal-1")
    // Preference: brew wins when available.
    expect(spawns[0]?.command).toBe("brew install fake-cli")
    expect(events.at(-1)?.payload.lifecycle?.phase).toBe("installing")

    // A second begin while running is refused.
    await expect(lifecycle.beginInstall("fake-cli")).rejects.toThrow(/already running/)

    processes[0]?.emitOutput("downloading…\n")
    processes[0]?.emitExit(0)
    await flush()
    expect(outputs.join("")).toContain("downloading…")
    expect(refreshes.length).toBeGreaterThan(0)
    expect(events.at(-1)?.payload.lifecycle?.phase).toBe("idle")
  })

  it("marks a failed install with the output tail and allows retry", async () => {
    const db = await makeDb()
    const bin = makeBinDir(["npm"])
    const agents = {
      catalog: [installableDefinition],
      discoverHarnesses: Effect.succeed([]),
      refreshEnvironment: Effect.void
    } as unknown as AgentRuntimeService
    const { terminal } = fakeTerminal()
    const { processes, spawnShell } = fakeSpawner()
    const lifecycle = makeHarnessLifecycleManager({
      agents,
      db,
      resolveEnv: async () => ({ PATH: bin }),
      spawnShell,
      terminal
    })

    await lifecycle.beginInstall("fake-cli", "npm")
    processes[0]?.emitOutput("npm ERR! registry unreachable\n")
    processes[0]?.emitExit(1)
    await flush()

    const decorated = await lifecycle.decorateHarnesses([
      harness("fake-cli", "/Users/dev/.local/bin/fake-cli")
    ])
    expect(decorated[0]?.lifecycle).toMatchObject({
      error: expect.stringContaining("registry unreachable"),
      phase: "failed",
      terminalId: "terminal-1"
    })

    // Failed state does not block a retry.
    await expect(lifecycle.beginInstall("fake-cli", "npm")).resolves.toMatchObject({
      terminalId: "terminal-1"
    })
  })

  it("updates via the native self-updater with the source's env opt-in", async () => {
    const db = await makeDb()
    const bin = makeBinDir(["npm"])
    const agents = {
      catalog: [installableDefinition],
      discoverHarnesses: Effect.succeed([
        harness("fake-cli", "/Users/dev/.local/bin/fake-cli", "1.0.0")
      ]),
      refreshEnvironment: Effect.void
    } as unknown as AgentRuntimeService
    const { terminal } = fakeTerminal()
    const { processes, spawnShell, spawns } = fakeSpawner()
    const lifecycle = makeHarnessLifecycleManager({
      agents,
      db,
      home: "/Users/dev",
      realpath: (path) => path,
      resolveEnv: async () => ({ PATH: bin }),
      spawnShell,
      terminal
    })

    const outcome = await lifecycle.beginUpdate("fake-cli")
    expect(outcome).toMatchObject({ queued: false, terminalId: "terminal-1" })
    expect(spawns[0]?.command).toBe("/Users/dev/.local/bin/fake-cli update")
    expect(spawns[0]?.env.FAKE_UPDATE_OPTIN).toBe("1")
    processes[0]?.emitExit(0)
    await flush()
  })

  it("does not clear updating when a zero-exit updater has not installed the target", async () => {
    const db = await makeDb()
    const bin = makeBinDir(["npm"])
    const agents = {
      catalog: [installableDefinition],
      discoverHarnesses: Effect.succeed([
        harness("fake-cli", "/Users/dev/.local/bin/fake-cli", "1.0.0")
      ]),
      refreshEnvironment: Effect.void
    } as unknown as AgentRuntimeService
    const { terminal } = fakeTerminal()
    const { processes, spawnShell } = fakeSpawner()
    const lifecycle = makeHarnessLifecycleManager({
      agents,
      db,
      fetchImpl: async () => jsonResponse({ "dist-tags": { latest: "2.0.0" } }),
      home: "/Users/dev",
      realpath: (path) => path,
      resolveEnv: async () => ({ PATH: bin }),
      spawnShell,
      terminal,
      updateVerificationPollIntervalMs: 1,
      updateVerificationTimeoutMs: 20
    })

    await lifecycle.checkForUpdates(true)
    const started = await lifecycle.beginUpdate("fake-cli")
    expect(started.lifecycle?.phase).toBe("updating")
    processes[0]?.emitExit(0)

    const whileVerifying = await lifecycle.decorateHarnesses([
      harness("fake-cli", "/Users/dev/.local/bin/fake-cli", "1.0.0")
    ])
    expect(whileVerifying[0]?.lifecycle?.phase).toBe("updating")
    await expect
      .poll(async () => {
        const decorated = await lifecycle.decorateHarnesses([
          harness("fake-cli", "/Users/dev/.local/bin/fake-cli", "1.0.0")
        ])
        return decorated[0]?.lifecycle
      })
      .toMatchObject({
        error: expect.stringContaining("still 1.0.0; expected 2.0.0"),
        phase: "failed"
      })
  })

  it("updates via reinstall for origins whose self-update is unsafe", async () => {
    const db = await makeDb()
    const bin = makeBinDir(["brew", "npm"])
    const definition: HarnessDefinition = {
      ...installableDefinition,
      update: {
        sources: [
          {
            apply: { kind: "reinstall" },
            check: { formula: "fake-cli", kind: "brew" },
            when: "brew"
          }
        ]
      }
    }
    const agents = {
      catalog: [definition],
      discoverHarnesses: Effect.succeed([
        harness("fake-cli", "/opt/homebrew/Cellar/fake-cli/1.0.0/bin/fake-cli", "1.0.0")
      ]),
      refreshEnvironment: Effect.void
    } as unknown as AgentRuntimeService
    const { terminal } = fakeTerminal()
    const { spawnShell, spawns } = fakeSpawner()
    const lifecycle = makeHarnessLifecycleManager({
      agents,
      db,
      home: "/Users/dev",
      realpath: (path) => path,
      resolveEnv: async () => ({ PATH: bin }),
      spawnShell,
      terminal
    })

    await lifecycle.beginUpdate("fake-cli")
    expect(spawns[0]?.command).toBe("brew upgrade fake-cli")
  })

  it("checks and updates Homebrew Claude through its owning cask", async () => {
    const db = await makeDb()
    const definition = harnessCatalog.find((candidate) => candidate.id === "claude-code")
    expect(definition).toBeDefined()
    if (definition === undefined) return

    const binary = "/opt/homebrew/Caskroom/claude-code@latest/2.1.215/claude"
    let installedVersion = "2.1.215"
    const agents = {
      catalog: [definition],
      discoverHarnesses: Effect.sync(() => [
        harness("claude-code", "/opt/homebrew/bin/claude", installedVersion)
      ]),
      refreshEnvironment: Effect.sync(() => {
        installedVersion = "2.1.216"
      })
    } as unknown as AgentRuntimeService
    const requests: string[] = []
    const fetchImpl: FetchLike = async (url) => {
      requests.push(url)
      return url.includes("/api/cask/claude-code%40latest.json")
        ? jsonResponse({ version: "2.1.216" })
        : jsonResponse({}, 404)
    }
    const bin = makeBinDir(["brew"])
    const { terminal } = fakeTerminal()
    const { processes, spawnShell, spawns } = fakeSpawner()
    const lifecycle = makeHarnessLifecycleManager({
      agents,
      db,
      fetchImpl,
      realpath: () => binary,
      resolveEnv: async () => ({ PATH: bin }),
      spawnShell,
      terminal
    })

    const outcomes = await lifecycle.checkForUpdates(true)
    expect(outcomes[0]?.info).toMatchObject({
      installOrigin: "brew",
      latestVersion: "2.1.216",
      source: "brew",
      updateAvailable: true
    })
    expect(requests.some((url) => url.includes("registry.npmjs.org"))).toBe(false)

    await lifecycle.beginUpdate("claude-code")
    expect(spawns[0]?.command).toBe("brew upgrade --cask claude-code@latest")
    processes[0]?.emitExit(0)
    await expect
      .poll(async () => (await run(db.listHarnessUpdateStates))[0]?.info.updateAvailable)
      .toBe(false)
  })

  it("checks and updates npm-owned Claude through npm", async () => {
    const db = await makeDb()
    const definition = harnessCatalog.find((candidate) => candidate.id === "claude-code")
    expect(definition).toBeDefined()
    if (definition === undefined) return

    const binary = "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"
    let installedVersion = "2.1.215"
    const agents = {
      catalog: [definition],
      discoverHarnesses: Effect.sync(() => [
        harness("claude-code", "/opt/homebrew/bin/claude", installedVersion)
      ]),
      refreshEnvironment: Effect.sync(() => {
        installedVersion = "2.1.216"
      })
    } as unknown as AgentRuntimeService
    const requests: string[] = []
    const fetchImpl: FetchLike = async (url) => {
      requests.push(url)
      return url.includes("registry.npmjs.org/@anthropic-ai/claude-code")
        ? jsonResponse({ "dist-tags": { latest: "2.1.216" } })
        : jsonResponse({}, 404)
    }
    const bin = makeBinDir(["npm"])
    const { terminal } = fakeTerminal()
    const { processes, spawnShell, spawns } = fakeSpawner()
    const lifecycle = makeHarnessLifecycleManager({
      agents,
      db,
      fetchImpl,
      realpath: () => binary,
      resolveEnv: async () => ({ PATH: bin }),
      spawnShell,
      terminal
    })

    const outcomes = await lifecycle.checkForUpdates(true)
    expect(outcomes[0]?.info).toMatchObject({
      installOrigin: "npm",
      latestVersion: "2.1.216",
      source: "npm",
      updateAvailable: true
    })
    expect(requests.some((url) => url.includes("formulae.brew.sh"))).toBe(false)

    await lifecycle.beginUpdate("claude-code")
    expect(spawns[0]?.command).toBe("npm install -g @anthropic-ai/claude-code@latest")
    processes[0]?.emitExit(0)
    await expect
      .poll(async () => (await run(db.listHarnessUpdateStates))[0]?.info.updateAvailable)
      .toBe(false)
  })

  it("updates native Claude through Claude's self-updater", async () => {
    const db = await makeDb()
    const definition = harnessCatalog.find((candidate) => candidate.id === "claude-code")
    expect(definition).toBeDefined()
    if (definition === undefined) return

    const binary = "/Users/dev/.local/share/claude/versions/2.1.215"
    let installedVersion = "2.1.215"
    const agents = {
      catalog: [definition],
      discoverHarnesses: Effect.sync(() => [
        harness("claude-code", "/Users/dev/.local/bin/claude", installedVersion)
      ]),
      refreshEnvironment: Effect.sync(() => {
        installedVersion = "2.1.216"
      })
    } as unknown as AgentRuntimeService
    const { terminal } = fakeTerminal()
    const { processes, spawnShell, spawns } = fakeSpawner()
    const lifecycle = makeHarnessLifecycleManager({
      agents,
      db,
      fetchImpl: async () => jsonResponse({ "dist-tags": { latest: "2.1.216" } }),
      home: "/Users/dev",
      realpath: () => binary,
      resolveEnv: async () => ({ PATH: "" }),
      spawnShell,
      terminal
    })

    const outcomes = await lifecycle.checkForUpdates(true)
    expect(outcomes[0]?.info).toMatchObject({ installOrigin: "curl", source: "npm" })

    await lifecycle.beginUpdate("claude-code")
    expect(spawns[0]?.command).toBe("/Users/dev/.local/bin/claude update")
    processes[0]?.emitExit(0)
    await expect
      .poll(async () => (await run(db.listHarnessUpdateStates))[0]?.info.updateAvailable)
      .toBe(false)
  })
})
