import type { AgentRuntimeService } from "@codevisor/agent-runtime"
import { Effect } from "effect"
import { makeHarnessLifecycleManager } from "./harness-lifecycle.js"
import { afterEach, describe, expect, it } from "vitest"
import {
  cleanupLifecycleTests,
  run,
  makeDb,
  harness,
  jsonResponse,
  makeBinDir,
  fakeTerminal,
  fakeSpawner,
  installableDefinition,
  appBundleDefinition
} from "./harness-lifecycle-test-support.js"

afterEach(cleanupLifecycleTests)

describe("harness lifecycle app-bundle swaps and the when-idle gate", () => {
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

    await expect(lifecycle.beginUpdate("fake-cli")).resolves.toMatchObject({
      lifecycle: { phase: "updating" },
      queued: false
    })
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
    await expect(lifecycle.beginUpdate("fake-cli")).resolves.toMatchObject({
      lifecycle: { phase: "pendingUpdate" },
      queued: true
    })
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
})
