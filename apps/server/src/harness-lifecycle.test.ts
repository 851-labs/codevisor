import type { AgentRuntimeService, HarnessDefinition } from "@codevisor/agent-runtime"
import type { Harness } from "@codevisor/api"
import { makeDatabase, type CodevisorDatabaseService } from "@codevisor/db"
import type { TerminalManagerService } from "@codevisor/terminal"
import { Effect } from "effect"
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterEach, describe, expect, it } from "vitest"
import {
  makeHarnessLifecycleManager,
  appBundlePath,
  type LifecycleProcess
} from "./harness-lifecycle.js"
import type { FetchLike } from "./harness-update-sources.js"

const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

const directories: string[] = []
const databases: CodevisorDatabaseService[] = []

afterEach(async () => {
  await Promise.all(databases.splice(0).map((database) => run(database.close)))
  for (const directory of directories.splice(0)) {
    rmSync(directory, { force: true, recursive: true })
  }
})

const makeDb = async (): Promise<CodevisorDatabaseService> => {
  const directory = mkdtempSync(join(tmpdir(), "codevisor-lifecycle-"))
  directories.push(directory)
  const db = await run(
    makeDatabase({ filename: join(directory, "codevisor.sqlite"), serverId: "test" })
  )
  databases.push(db)
  return db
}

const harness = (id: string, path: string, version?: string): Harness => ({
  id,
  name: id,
  symbolName: "terminal",
  source: "registry",
  launchKind: "executable",
  enabled: true,
  readiness: { state: "ready", path, ...(version === undefined ? {} : { version }) }
})

const agentsStub = (
  definitions: ReadonlyArray<HarnessDefinition>,
  harnesses: ReadonlyArray<Harness>
): AgentRuntimeService =>
  ({
    catalog: definitions,
    discoverHarnesses: Effect.succeed(harnesses)
  }) as unknown as AgentRuntimeService

const npmDefinition: HarnessDefinition = {
  detectBinaries: ["fake-cli"],
  id: "fake-cli",
  launch: { args: ["acp"], command: "fake-cli", kind: "executable" },
  name: "Fake CLI",
  provider: "acp",
  symbolName: "terminal",
  update: {
    sources: [
      {
        apply: { args: ["update"], kind: "selfUpdate" },
        check: { kind: "npm", packageName: "fake-cli" },
        when: "any"
      }
    ]
  }
}

const jsonResponse = (body: unknown, status = 200) => ({
  ok: status >= 200 && status < 300,
  status,
  json: async () => body,
  text: async () => (typeof body === "string" ? body : JSON.stringify(body))
})

describe("harness lifecycle update detection", () => {
  it("checks, persists, decorates, and emits only on change", async () => {
    const db = await makeDb()
    const fetchImpl: FetchLike = async (url) =>
      url.includes("registry.npmjs.org")
        ? jsonResponse({ "dist-tags": { latest: "2.0.0" } })
        : jsonResponse({}, 404)
    const events: Array<unknown> = []
    const lifecycle = makeHarnessLifecycleManager({
      agents: agentsStub(
        [npmDefinition],
        [harness("fake-cli", "/Users/dev/.local/bin/fake-cli", "1.0.0")]
      ),
      db,
      fetchImpl,
      home: "/Users/dev",
      realpath: (path) => path
    })
    lifecycle.subscribe((event) => events.push(event))

    const outcomes = await lifecycle.checkForUpdates(true)
    expect(outcomes).toEqual([
      {
        harnessId: "fake-cli",
        info: expect.objectContaining({
          installOrigin: "curl",
          installedVersion: "1.0.0",
          latestVersion: "2.0.0",
          source: "npm",
          updateAvailable: true
        })
      }
    ])
    expect(events).toHaveLength(1)

    // Same knowledge on a re-check → no duplicate event.
    await lifecycle.checkForUpdates(true)
    expect(events).toHaveLength(1)

    // Persisted state survives a fresh manager (server restart).
    const rebooted = makeHarnessLifecycleManager({
      agents: agentsStub([npmDefinition], []),
      db,
      fetchImpl
    })
    const decorated = await rebooted.decorateHarnesses([
      harness("fake-cli", "/Users/dev/.local/bin/fake-cli", "1.0.0")
    ])
    expect(decorated[0]?.updateInfo).toMatchObject({
      latestVersion: "2.0.0",
      updateAvailable: true
    })
  })

  it("suppresses unforced re-checks inside the cache window", async () => {
    const db = await makeDb()
    let calls = 0
    const fetchImpl: FetchLike = async () => {
      calls += 1
      return jsonResponse({ "dist-tags": { latest: "2.0.0" } })
    }
    const lifecycle = makeHarnessLifecycleManager({
      agents: agentsStub(
        [npmDefinition],
        [harness("fake-cli", "/Users/dev/.local/bin/fake-cli", "1.0.0")]
      ),
      db,
      fetchImpl,
      home: "/Users/dev",
      realpath: (path) => path
    })
    await lifecycle.checkForUpdates(true)
    expect(calls).toBe(1)
    await expect(lifecycle.checkForUpdates()).resolves.toEqual([])
    expect(calls).toBe(1)
  })

  it("compares app-bundle installs against the app version via the sparkle feed", async () => {
    const db = await makeDb()
    const appcast = `<rss><channel><item>
      <sparkle:version>5591</sparkle:version>
      <sparkle:shortVersionString>26.715.52143</sparkle:shortVersionString>
      <enclosure url="https://example.com/ChatGPT.zip" length="1" sparkle:edSignature="sig==" />
    </item></channel></rss>`
    const definition: HarnessDefinition = {
      detectBinaries: ["codex"],
      id: "codex-like",
      name: "Codex Like",
      provider: "codex",
      symbolName: "terminal",
      update: {
        sources: [
          {
            apply: { kind: "appBundleSwap" },
            check: { appcastUrl: "https://example.com/appcast.xml", kind: "sparkle" },
            when: "appBundle"
          }
        ]
      }
    }
    const lifecycle = makeHarnessLifecycleManager({
      agents: agentsStub(
        [definition],
        [
          // The CLI's own version channel runs ahead — it must NOT be used.
          harness(
            "codex-like",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "0.145.0-alpha.18"
          )
        ]
      ),
      db,
      fetchImpl: async () => jsonResponse(appcast),
      home: "/Users/dev",
      platform: "darwin",
      readBundleShortVersion: async (bundlePath) =>
        bundlePath === "/Applications/ChatGPT.app" ? "26.715.31925" : undefined,
      realpath: (path) => path
    })

    const outcomes = await lifecycle.checkForUpdates(true)
    expect(outcomes[0]?.info).toMatchObject({
      channel: "app",
      installOrigin: "appBundle",
      installedVersion: "26.715.31925",
      latestVersion: "26.715.52143",
      source: "sparkle",
      updateAvailable: true
    })
  })

  it("skips app-bundle checks off darwin and harnesses without sources", async () => {
    const db = await makeDb()
    const definition: HarnessDefinition = {
      detectBinaries: ["codex"],
      id: "codex-like",
      name: "Codex Like",
      provider: "codex",
      symbolName: "terminal",
      update: {
        sources: [
          {
            apply: { kind: "appBundleSwap" },
            check: { appcastUrl: "https://example.com/appcast.xml", kind: "sparkle" },
            when: "appBundle"
          }
        ]
      }
    }
    const lifecycle = makeHarnessLifecycleManager({
      agents: agentsStub(
        [definition],
        [harness("codex-like", "/Applications/ChatGPT.app/Contents/Resources/codex")]
      ),
      db,
      fetchImpl: async () => jsonResponse({}, 500),
      platform: "linux",
      realpath: (path) => path
    })
    await expect(lifecycle.checkForUpdates(true)).resolves.toEqual([])
  })

  it("derives the bundle path from the binary path", () => {
    expect(appBundlePath("/Applications/ChatGPT.app/Contents/Resources/codex")).toBe(
      "/Applications/ChatGPT.app"
    )
    expect(appBundlePath("/usr/local/bin/codex")).toBeUndefined()
  })
})

/// A PATH directory with executable stubs, for install-method availability.
const makeBinDir = (names: ReadonlyArray<string>): string => {
  const dir = mkdtempSync(join(tmpdir(), "codevisor-bin-"))
  directories.push(dir)
  for (const name of names) {
    const path = join(dir, name)
    writeFileSync(path, "#!/bin/sh\n")
    chmodSync(path, 0o755)
  }
  return dir
}

const fakeTerminal = () => {
  const outputs: Array<string> = []
  const exits: Array<number | undefined> = []
  const terminal = {
    registerExternalTerminal: () => ({
      exit: (code?: number) => exits.push(code),
      output: (data: string) => outputs.push(data),
      remove: () => {},
      response: {} as never,
      terminalId: "terminal-1"
    })
  } as unknown as TerminalManagerService
  return { exits, outputs, terminal }
}

/// Manually-settled fake process so tests control exit timing.
const fakeSpawner = () => {
  const spawns: Array<{ command: string; env: NodeJS.ProcessEnv }> = []
  const processes: Array<{
    emitOutput: (data: string) => void
    emitExit: (code: number | undefined) => void
    killed: boolean
  }> = []
  const spawnShell = (command: string, env: NodeJS.ProcessEnv): LifecycleProcess => {
    spawns.push({ command, env })
    const outputListeners: Array<(data: string) => void> = []
    const exitListeners: Array<(code: number | undefined) => void> = []
    const record = {
      emitExit: (code: number | undefined) => {
        for (const listener of exitListeners) listener(code)
      },
      emitOutput: (data: string) => {
        for (const listener of outputListeners) listener(data)
      },
      killed: false
    }
    processes.push(record)
    return {
      kill: () => {
        record.killed = true
      },
      onExit: (listener) => exitListeners.push(listener),
      onOutput: (listener) => outputListeners.push(listener)
    }
  }
  return { processes, spawnShell, spawns }
}

const installableDefinition: HarnessDefinition = {
  detectBinaries: ["fake-cli"],
  id: "fake-cli",
  installMethods: [
    { formula: "fake-cli", kind: "brew" },
    { kind: "npm", packageName: "fake-cli" }
  ],
  launch: { args: ["acp"], command: "fake-cli", kind: "executable" },
  name: "Fake CLI",
  provider: "acp",
  symbolName: "terminal",
  update: {
    sources: [
      {
        apply: { args: ["update"], env: { FAKE_UPDATE_OPTIN: "1" }, kind: "selfUpdate" },
        check: { kind: "npm", packageName: "fake-cli" },
        when: "any"
      }
    ]
  }
}

const flush = () => new Promise((resolve) => setTimeout(resolve, 0))

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

  const appBundleDefinition: HarnessDefinition = {
    ...installableDefinition,
    update: {
      sources: [
        {
          apply: { kind: "appBundleSwap" },
          check: { appcastUrl: "https://example.com/appcast.xml", kind: "sparkle" },
          when: "appBundle"
        }
      ]
    }
  }

  it("performs the app-bundle swap through the injected verifier", async () => {
    const db = await makeDb()
    const swaps: Array<{ bundlePath: string }> = []
    const events: Array<{ payload: { lifecycle?: { phase?: string } } }> = []
    const { terminal } = fakeTerminal()
    const lifecycle = makeHarnessLifecycleManager({
      agents: {
        catalog: [appBundleDefinition],
        discoverHarnesses: Effect.succeed([
          harness("fake-cli", "/Applications/ChatGPT.app/Contents/Resources/codex")
        ]),
        refreshEnvironment: Effect.void
      } as unknown as AgentRuntimeService,
      applyBundleSwap: async (options) => {
        swaps.push({ bundlePath: options.bundlePath })
        return { installedVersion: "26.715.52143" }
      },
      db,
      fetchImpl: async () => ({
        json: async () => ({}),
        ok: true,
        status: 200,
        text: async () => "<rss>feed</rss>"
      }),
      platform: "darwin",
      realpath: (path) => path,
      resolveEnv: async () => ({}),
      terminal
    })
    lifecycle.subscribe((event) => events.push(event as never))

    await expect(lifecycle.beginUpdate("fake-cli")).resolves.toEqual({ queued: false })
    expect(events.at(-1)?.payload.lifecycle?.phase).toBe("updating")
    await expect.poll(() => events.at(-1)?.payload.lifecycle?.phase).toBe("idle")
    expect(swaps).toEqual([{ bundlePath: "/Applications/ChatGPT.app" }])
  })

  it("fails the operation when the swap verifier rejects", async () => {
    const db = await makeDb()
    const { terminal } = fakeTerminal()
    const lifecycle = makeHarnessLifecycleManager({
      agents: {
        catalog: [appBundleDefinition],
        discoverHarnesses: Effect.succeed([
          harness("fake-cli", "/Applications/ChatGPT.app/Contents/Resources/codex")
        ]),
        refreshEnvironment: Effect.void
      } as unknown as AgentRuntimeService,
      applyBundleSwap: async () => {
        throw new Error("The download failed Sparkle signature verification")
      },
      db,
      fetchImpl: async () => ({
        json: async () => ({}),
        ok: true,
        status: 200,
        text: async () => "<rss>feed</rss>"
      }),
      platform: "darwin",
      realpath: (path) => path,
      resolveEnv: async () => ({}),
      terminal
    })

    await lifecycle.beginUpdate("fake-cli")
    await expect
      .poll(async () => {
        const decorated = await lifecycle.decorateHarnesses([
          harness("fake-cli", "/Applications/ChatGPT.app/Contents/Resources/codex")
        ])
        return decorated[0]?.lifecycle?.phase
      })
      .toBe("failed")
    const decorated = await lifecycle.decorateHarnesses([
      harness("fake-cli", "/Applications/ChatGPT.app/Contents/Resources/codex")
    ])
    expect(decorated[0]?.lifecycle?.error).toContain("Sparkle signature")
  })

  it("arms a durable pending update while the harness is busy, then runs it when idle", async () => {
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
    const released: Array<string> = []
    const lifecycle = makeHarnessLifecycleManager({
      agents,
      db,
      fetchImpl: async () => jsonResponse({}, 404),
      home: "/Users/dev",
      realpath: (path) => path,
      resolveEnv: async () => ({ PATH: bin }),
      spawnShell,
      terminal
    })
    lifecycle.onGateReleased((harnessId) => released.push(harnessId))

    // Two turns in flight → arm instead of running.
    lifecycle.notifyTurnStarted("fake-cli")
    lifecycle.notifyTurnStarted("fake-cli")
    await expect(lifecycle.beginUpdate("fake-cli")).resolves.toEqual({ queued: true })
    expect(spawns).toHaveLength(0)
    expect(lifecycle.isGated("fake-cli")).toBe(false)
    await expect(run(db.listHarnessPendingUpdates)).resolves.toMatchObject([
      { harnessId: "fake-cli", state: "pending" }
    ])

    // First turn ends → still busy, nothing runs.
    lifecycle.notifyTurnEnded("fake-cli")
    expect(spawns).toHaveLength(0)

    // Last turn ends → the armed update executes and gates dispatch.
    lifecycle.notifyTurnEnded("fake-cli")
    await expect.poll(() => spawns.length).toBe(1)
    expect(lifecycle.isGated("fake-cli")).toBe(true)
    await expect(run(db.listHarnessPendingUpdates)).resolves.toMatchObject([
      { harnessId: "fake-cli", state: "running" }
    ])

    // Completion releases the gate and clears the durable row.
    processes[0]?.emitExit(0)
    await expect.poll(() => released).toEqual(["fake-cli"])
    expect(lifecycle.isGated("fake-cli")).toBe(false)
    await expect(run(db.listHarnessPendingUpdates)).resolves.toEqual([])
  })

  it("releases the gate on failure, supports Update Now and cancel", async () => {
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
    const released: Array<string> = []
    const lifecycle = makeHarnessLifecycleManager({
      agents,
      db,
      home: "/Users/dev",
      realpath: (path) => path,
      resolveEnv: async () => ({ PATH: bin }),
      spawnShell,
      terminal
    })
    lifecycle.onGateReleased((harnessId) => released.push(harnessId))

    // Cancel disarms without running anything.
    lifecycle.notifyTurnStarted("fake-cli")
    await lifecycle.beginUpdate("fake-cli")
    await lifecycle.cancelPendingUpdate("fake-cli")
    await expect(run(db.listHarnessPendingUpdates)).resolves.toEqual([])
    await expect(lifecycle.cancelPendingUpdate("fake-cli")).rejects.toThrow(/No pending update/)

    // Update Now skips the idle wait; a failing update still releases.
    await lifecycle.beginUpdate("fake-cli")
    await lifecycle.forcePendingUpdate("fake-cli")
    await expect.poll(() => spawns.length).toBe(1)
    expect(lifecycle.isGated("fake-cli")).toBe(true)
    processes[0]?.emitExit(1)
    await expect.poll(() => released).toEqual(["fake-cli"])
    expect(lifecycle.isGated("fake-cli")).toBe(false)
  })

  it("dispatches immediately with the gate kill switch off", async () => {
    const db = await makeDb()
    const bin = makeBinDir(["npm"])
    const { terminal } = fakeTerminal()
    const { spawnShell, spawns } = fakeSpawner()
    const lifecycle = makeHarnessLifecycleManager({
      agents: {
        catalog: [installableDefinition],
        discoverHarnesses: Effect.succeed([
          harness("fake-cli", "/Users/dev/.local/bin/fake-cli", "1.0.0")
        ]),
        refreshEnvironment: Effect.void
      } as unknown as AgentRuntimeService,
      db,
      gateEnabled: false,
      home: "/Users/dev",
      realpath: (path) => path,
      resolveEnv: async () => ({ PATH: bin }),
      spawnShell,
      terminal
    })
    lifecycle.notifyTurnStarted("fake-cli")
    await expect(lifecycle.beginUpdate("fake-cli")).resolves.toMatchObject({ queued: false })
    expect(spawns).toHaveLength(1)
    expect(lifecycle.isGated("fake-cli")).toBe(false)
  })

  it("reconciles interrupted and armed updates at startup", async () => {
    const db = await makeDb()
    await run(
      db.setHarnessPendingUpdate({
        harnessId: "fake-cli",
        requestedAt: "2026-07-20T00:00:00.000Z",
        startedAt: "2026-07-20T00:01:00.000Z",
        state: "running",
        targetVersion: "2.0.0",
        timeoutAt: "2026-07-20T00:11:00.000Z"
      })
    )
    const events: Array<{ payload: { lifecycle?: { phase?: string; error?: string } } }> = []
    const lifecycle = makeHarnessLifecycleManager({
      agents: {
        catalog: [installableDefinition],
        discoverHarnesses: Effect.succeed([]),
        refreshEnvironment: Effect.void
      } as unknown as AgentRuntimeService,
      db
    })
    lifecycle.subscribe((event) => events.push(event as never))

    await lifecycle.reconcileOnStartup()
    // The interrupted update becomes a failure — never a surviving gate.
    expect(lifecycle.isGated("fake-cli")).toBe(false)
    await expect(run(db.listHarnessPendingUpdates)).resolves.toEqual([])
    expect(events.at(-1)?.payload.lifecycle).toMatchObject({
      error: expect.stringContaining("restart"),
      phase: "failed"
    })
  })

  it("reports and updates the bundled desktop app for dual installs", async () => {
    const db = await makeDb()
    // A fake app bundle with an executable CLI inside, so the fallback-path
    // probe (accessSync X_OK) finds it like the real ChatGPT.app copy.
    const appDir = mkdtempSync(join(tmpdir(), "codevisor-app-"))
    directories.push(appDir)
    const bundle = join(appDir, "FakeChat.app")
    const resources = join(bundle, "Contents", "Resources")
    mkdirSync(resources, { recursive: true })
    const bundledBinary = join(resources, "codex")
    writeFileSync(bundledBinary, "#!/bin/sh\n")
    chmodSync(bundledBinary, 0o755)

    const appcast = `<rss><channel><item>
      <sparkle:shortVersionString>26.715.52143</sparkle:shortVersionString>
      <enclosure url="https://example.com/FakeChat.zip" length="1" sparkle:edSignature="sig==" />
    </item></channel></rss>`
    const definition: HarnessDefinition = {
      ...installableDefinition,
      fallbackPaths: [bundledBinary],
      update: {
        sources: [
          {
            apply: { kind: "appBundleSwap" },
            check: { appcastUrl: "https://example.com/appcast.xml", kind: "sparkle" },
            when: "appBundle"
          },
          {
            apply: { args: ["update"], kind: "selfUpdate" },
            check: { kind: "npm", packageName: "fake-cli" },
            when: "any"
          }
        ]
      }
    }
    const swaps: Array<string> = []
    const lifecycle = makeHarnessLifecycleManager({
      agents: {
        catalog: [definition],
        // Primary install is the user's own CLI — NOT the bundle.
        discoverHarnesses: Effect.succeed([
          harness("fake-cli", "/Users/dev/.local/bin/fake-cli", "1.0.0")
        ]),
        refreshEnvironment: Effect.void
      } as unknown as AgentRuntimeService,
      applyBundleSwap: async (options) => {
        swaps.push(options.bundlePath)
        return { installedVersion: "26.715.52143" }
      },
      db,
      fetchImpl: async (url) =>
        url.includes("appcast")
          ? jsonResponse(appcast)
          : jsonResponse({ "dist-tags": { latest: "1.0.0" } }),
      platform: "darwin",
      readBundleShortVersion: async (path) => (path === bundle ? "26.715.31925" : undefined),
      realpath: (path) => path,
      resolveEnv: async () => ({})
    })

    await expect(lifecycle.bundledAppInfo("fake-cli")).resolves.toEqual({
      appName: "FakeChat",
      bundlePath: bundle,
      installedVersion: "26.715.31925",
      latestVersion: "26.715.52143",
      updateAvailable: true
    })

    await lifecycle.beginBundledAppUpdate("fake-cli")
    await expect.poll(() => swaps).toEqual([bundle])
  })

  it("reports no bundled app when the bundle is absent or off darwin", async () => {
    const db = await makeDb()
    const definition: HarnessDefinition = {
      ...installableDefinition,
      fallbackPaths: ["/nonexistent/FakeChat.app/Contents/Resources/codex"],
      update: {
        sources: [
          {
            apply: { kind: "appBundleSwap" },
            check: { appcastUrl: "https://example.com/appcast.xml", kind: "sparkle" },
            when: "appBundle"
          }
        ]
      }
    }
    const lifecycle = makeHarnessLifecycleManager({
      agents: {
        catalog: [definition],
        discoverHarnesses: Effect.succeed([]),
        refreshEnvironment: Effect.void
      } as unknown as AgentRuntimeService,
      db,
      platform: "darwin",
      resolveEnv: async () => ({})
    })
    await expect(lifecycle.bundledAppInfo("fake-cli")).resolves.toBeUndefined()
    await expect(lifecycle.beginBundledAppUpdate("fake-cli")).rejects.toThrow(/no bundled/)
  })

  it("refuses app-bundle swaps off darwin", async () => {
    const db = await makeDb()
    const { terminal } = fakeTerminal()
    const lifecycle = makeHarnessLifecycleManager({
      agents: {
        catalog: [appBundleDefinition],
        discoverHarnesses: Effect.succeed([
          harness("fake-cli", "/Applications/ChatGPT.app/Contents/Resources/codex")
        ]),
        refreshEnvironment: Effect.void
      } as unknown as AgentRuntimeService,
      db,
      platform: "linux",
      realpath: (path) => path,
      resolveEnv: async () => ({}),
      terminal
    })
    await expect(lifecycle.beginUpdate("fake-cli")).rejects.toThrow(/desktop app/)
  })
})
