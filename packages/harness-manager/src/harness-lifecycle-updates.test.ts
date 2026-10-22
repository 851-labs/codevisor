import { Effect } from "effect"
import { afterEach, describe, expect, it } from "vitest"

import { fakeAgentRuntime } from "./harness-lifecycle-test-support.js"
import {
  cleanupLifecycleTests,
  makeDb,
  harness,
  jsonResponse,
  makeBinDir,
  fakeTerminal,
  fakeSpawner,
  installableDefinition,
  appBundleDefinition
} from "./harness-lifecycle-test-support.js"
import { makeHarnessLifecycleManager } from "./harness-lifecycle.js"

afterEach(cleanupLifecycleTests)

describe("harness lifecycle updates", () => {
  it("performs the app-bundle swap through the injected verifier", async () => {
    const db = await makeDb()
    const swaps: Array<{ bundlePath: string }> = []
    const events: Array<{ payload: { lifecycle?: { phase?: string } } }> = []
    const { terminal } = fakeTerminal()
    const lifecycle = makeHarnessLifecycleManager({
      agents: fakeAgentRuntime({
        catalog: [appBundleDefinition],
        discoverHarnesses: Effect.succeed([
          harness("fake-cli", "/Applications/ChatGPT.app/Contents/Resources/codex")
        ]),
        refreshEnvironment: Effect.void
      }),
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
    lifecycle.subscribe((event) => events.push(event))

    const applied = lifecycle.applyUpdate("fake-cli")
    await expect(applied).resolves.toBe(true)
    expect(events.map((event) => event.payload.lifecycle?.phase)).toContain("updating")
    expect(events.at(-1)?.payload.lifecycle?.phase).toBe("idle")
    expect(swaps).toEqual([{ bundlePath: "/Applications/ChatGPT.app" }])
  })

  it("fails the operation when the swap verifier rejects", async () => {
    const db = await makeDb()
    const { terminal } = fakeTerminal()
    const lifecycle = makeHarnessLifecycleManager({
      agents: fakeAgentRuntime({
        catalog: [appBundleDefinition],
        discoverHarnesses: Effect.succeed([
          harness("fake-cli", "/Applications/ChatGPT.app/Contents/Resources/codex")
        ]),
        refreshEnvironment: Effect.void
      }),
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

    await expect(lifecycle.applyUpdate("fake-cli")).resolves.toBe(false)
    const decorated = await lifecycle.decorateHarnesses([
      harness("fake-cli", "/Applications/ChatGPT.app/Contents/Resources/codex")
    ])
    expect(decorated[0]?.lifecycle?.error).toContain("Sparkle signature")
  })

  it("shows a prepared update as updating toward the latest version until it is cancelled", async () => {
    const db = await makeDb()
    const bin = makeBinDir(["npm"])
    const { terminal } = fakeTerminal()
    const { spawnShell, spawns } = fakeSpawner()
    const lifecycle = makeHarnessLifecycleManager({
      agents: fakeAgentRuntime({
        catalog: [installableDefinition],
        discoverHarnesses: Effect.succeed([
          harness("fake-cli", "/Users/dev/.local/bin/fake-cli", "1.0.0")
        ]),
        refreshEnvironment: Effect.void
      }),
      db,
      fetchImpl: async () => jsonResponse({ "dist-tags": { latest: "2.0.0" } }),
      home: "/Users/dev",
      realpath: (path) => path,
      resolveEnv: async () => ({ PATH: bin }),
      spawnShell,
      terminal
    })
    await lifecycle.checkForUpdates(true)

    await expect(lifecycle.prepareUpdate("fake-cli")).resolves.toMatchObject({
      phase: "updating",
      targetVersion: "2.0.0"
    })
    await expect(lifecycle.prepareUpdate("fake-cli")).rejects.toThrow(/already running/)
    expect(spawns).toEqual([])

    lifecycle.cancelUpdate("fake-cli")
    const [cancelled] = await lifecycle.decorateHarnesses([
      harness("fake-cli", "/Users/dev/.local/bin/fake-cli", "1.0.0")
    ])
    expect(cancelled?.lifecycle).toBeUndefined()
  })

  it("applies a prepared update and reports whether the install succeeded", async () => {
    const db = await makeDb()
    const bin = makeBinDir(["npm"])
    const { terminal } = fakeTerminal()
    const { processes, spawnShell, spawned } = fakeSpawner()
    const lifecycle = makeHarnessLifecycleManager({
      agents: fakeAgentRuntime({
        catalog: [installableDefinition],
        discoverHarnesses: Effect.succeed([
          harness("fake-cli", "/Users/dev/.local/bin/fake-cli", "1.0.0")
        ]),
        refreshEnvironment: Effect.void
      }),
      db,
      home: "/Users/dev",
      realpath: (path) => path,
      resolveEnv: async () => ({ PATH: bin }),
      spawnShell,
      terminal
    })
    await lifecycle.prepareUpdate("fake-cli")

    const applied = lifecycle.applyUpdate("fake-cli")
    await spawned
    lifecycle.cancelUpdate("fake-cli")
    const [running] = await lifecycle.decorateHarnesses([
      harness("fake-cli", "/Users/dev/.local/bin/fake-cli", "1.0.0")
    ])
    expect(running?.lifecycle).toMatchObject({ phase: "updating", terminalId: "terminal-1" })
    processes[0]?.emitExit(1)

    await expect(applied).resolves.toBe(false)
  })

  it("fails an update whose harness was uninstalled while chats paused", async () => {
    const db = await makeDb()
    let installed = [harness("fake-cli", "/Users/dev/.local/bin/fake-cli", "1.0.0")]
    const lifecycle = makeHarnessLifecycleManager({
      agents: fakeAgentRuntime({
        catalog: [installableDefinition],
        discoverHarnesses: Effect.sync(() => installed),
        refreshEnvironment: Effect.void
      }),
      db,
      fetchImpl: async () => jsonResponse({ "dist-tags": { latest: "2.0.0" } }),
      home: "/Users/dev",
      realpath: (path) => path
    })
    await lifecycle.checkForUpdates(true)
    await lifecycle.prepareUpdate("fake-cli")
    installed = []

    await expect(lifecycle.applyUpdate("fake-cli")).resolves.toBe(false)
    const [failed] = await lifecycle.decorateHarnesses([harness("fake-cli", "/bin/fake-cli")])
    expect(failed?.lifecycle).toMatchObject({
      error: "fake-cli is not installed",
      phase: "failed",
      targetVersion: "2.0.0"
    })
  })
})
