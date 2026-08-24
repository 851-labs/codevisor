import { existsSync, writeFileSync } from "node:fs"
import { cp } from "node:fs/promises"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import type { PluginStateEvent } from "./plugins-manager.js"
import { exampleManifest, fakeSpawn, makeDir, makeManager } from "./test-support.js"

/// Manager-level wiring for the install pipeline: the installer runs behind
/// the same facade as the runtime, summaries come from a fresh scan, and list
/// changes fan out as plugin.state.updated events.

const makeFixture = (manifest: Record<string, unknown>): string => {
  const fixture = makeDir("codevisor-plugin-fixture-")
  writeFileSync(join(fixture, "codevisor-plugin.json"), JSON.stringify(manifest))
  return fixture
}

const freshManifest = {
  ...exampleManifest,
  iconPath: "/assets/icon.svg",
  id: "owner.fresh",
  name: "Fresh"
}

describe("manager install pipeline", () => {
  it("wires protocol v2 version and argv execution into the installer", async () => {
    const spawn = fakeSpawn()
    const { manager } = makeManager({
      codevisorVersion: "1.0.0",
      spawnArgv: (_argv, options) => spawn.spawnShell("unused", options)
    })
    await expect(manager.list()).resolves.toMatchObject({
      plugins: [expect.objectContaining({ id: "owner.example" })]
    })
  })

  it("discovers, imports, and removes a plugin through the facade", async () => {
    const fixture = makeFixture(freshManifest)
    const events: Array<PluginStateEvent> = []
    const { manager, root } = makeManager({
      clone: async (url, _ref, destination) => {
        await cp(url, destination, { recursive: true })
        return { resolvedCommit: "a".repeat(40) }
      },
      registerExternalTerminal: (_config, _process) => ({
        exit: () => undefined,
        output: () => undefined,
        terminalId: "terminal-1"
      })
    })
    manager.subscribe((event) => events.push(event))

    const discovered = await manager.discoverRemote({ source: fixture })
    expect(discovered.id).toBe("owner.fresh")
    expect(discovered.runCommand).toBe("run-me")
    expect(discovered.iconPath).toBe("/assets/icon.svg")
    expect(discovered.alreadyInstalled).toBe(false)

    const imported = await manager.importRemote({ source: fixture })
    expect(imported.id).toBe("owner.fresh")
    expect(imported.source).toBe("managed")
    expect(imported.state).toBe("running")
    expect(events.some((event) => event.subjectId === "owner.fresh")).toBe(true)
    expect(existsSync(join(root, "owner.fresh"))).toBe(true)

    const afterRemove = await manager.remove("owner.fresh")
    expect(afterRemove.plugins.map((plugin) => plugin.id)).toEqual(["owner.example"])
    expect(existsSync(join(root, "owner.fresh"))).toBe(false)
  })

  it("installs successfully even when the plugin immediately fails to start", async () => {
    const fixture = makeFixture(freshManifest)
    const spawn = fakeSpawn({ listen: false })
    const { manager } = makeManager({
      maxConsecutiveFailures: 1,
      readyTimeoutMs: 200,
      spawnShell: spawn.spawnShell
    })
    const linked = await manager.link({ path: fixture })
    expect(linked.state).toBe("failed")
  })

  it("installs plugins for another platform without starting them", async () => {
    const fixture = makeFixture({ ...freshManifest, platforms: ["never-os"] })
    const { manager } = makeManager({ platform: "darwin" })
    const linked = await manager.link({ path: fixture })
    expect(linked.state).toBe("stopped")
  })

  it("links a local plugin directory and reports it as linked", async () => {
    const fixture = makeFixture(freshManifest)
    const { manager, root } = makeManager()
    const linked = await manager.link({ path: fixture })
    expect(linked.id).toBe("owner.fresh")
    expect(linked.source).toBe("linked")
    expect(existsSync(join(root, "owner.fresh"))).toBe(true)
    // Linked plugins are refused by remove — they belong to the developer.
    await expect(manager.remove("owner.fresh")).rejects.toThrow(/linked, not managed/)
  })
})
