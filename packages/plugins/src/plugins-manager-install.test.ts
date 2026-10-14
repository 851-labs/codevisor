import { existsSync, writeFileSync } from "node:fs"
import { cp } from "node:fs/promises"
import { join } from "node:path"

import { describe, expect, it } from "vitest"

import type { PluginStateEvent } from "./plugins-manager.js"
import { advancingClock } from "./test-support.js"
import { exampleManifest, fakeSpawn, makeDir, makeManager } from "./test-support.js"

const makeFixture = (manifest: Record<string, unknown>): string => {
  const fixture = makeDir("codevisor-plugin-fixture-")
  writeFileSync(join(fixture, "codevisor-plugin.json"), JSON.stringify(manifest))
  return fixture
}

const freshManifest = {
  ...exampleManifest,
  ageRating: 9,
  iconPath: "/assets/icon.svg",
  id: "owner.fresh",
  name: "Fresh"
}

describe("manager install pipeline", () => {
  it("gates protocol v2 installs on the Codevisor version and runs them through argv", async () => {
    const v2Manifest = {
      ...freshManifest,
      minCodevisorVersion: "1.0.0",
      protocolVersion: 2,
      run: { argv: ["node", "server.js"] },
      setup: [{ argv: ["npm", "ci"] }]
    }
    const server = fakeSpawn()
    const spawned: Array<ReadonlyArray<string>> = []
    const { manager } = makeManager({
      clone: async (url, _ref, destination) => {
        await cp(url, destination, { recursive: true })
        return { resolvedCommit: "a".repeat(40) }
      },
      codevisorVersion: "1.0.0",
      spawnArgv: (argv, options) => {
        spawned.push(argv)
        if (argv[0] === "node") return server.spawnShell(argv.join(" "), options)
        const exitListeners: Array<(message: string, exitCode?: number | null) => void> = []
        setImmediate(() => {
          for (const listener of exitListeners) listener("exited with code 0", 0)
        })
        return { kill: () => undefined, onExit: (listener) => exitListeners.push(listener), pid: 7 }
      }
    })

    await expect(
      manager.importRemote({ source: makeFixture({ ...v2Manifest, minCodevisorVersion: "1.1.0" }) })
    ).rejects.toThrow(/requires Codevisor 1\.1\.0 or newer; this server is 1\.0\.0/)
    expect(spawned).toEqual([])

    const imported = await manager.importRemote({ source: makeFixture(v2Manifest) })
    expect(imported.state).toBe("running")
    expect(spawned).toEqual([
      ["npm", "ci"],
      ["node", "server.js"]
    ])
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
    expect(imported.ageRating).toBe(9)
    expect(discovered.ageRating).toBe(9)
    expect(imported.consentKey).toBe(discovered.consentKey)
    expect(imported.state).toBe("running")
    expect(events.some((event) => event.subjectId === "owner.fresh")).toBe(true)
    expect(existsSync(join(root, "owner.fresh"))).toBe(true)

    const afterRemove = await manager.remove("owner.fresh")
    expect(afterRemove.plugins.map((plugin) => plugin.id)).toEqual(["owner.example"])
    expect(existsSync(join(root, "owner.fresh"))).toBe(false)
  })

  it("checks, prepares, and applies a registry update through the facade", async () => {
    const fixture = makeFixture({ ...freshManifest, version: "1.0.0" })
    const commit = "b".repeat(40)
    const { manager } = makeManager({
      clone: async (_url, ref, destination) => {
        await cp(fixture, destination, { recursive: true })
        return { resolvedCommit: ref ?? "a".repeat(40) }
      },
      fetchPluginRegistry: async () => ({
        entries: [
          {
            commit,
            id: "owner.fresh",
            name: "Fresh",
            panes: freshManifest.panes,
            protocolVersion: 1,
            pushedAt: "2026-08-23T00:00:00.000Z",
            repo: "owner/fresh",
            stars: 1,
            version: "2.0.0"
          }
        ],
        generatedAt: "2026-08-23T00:00:00.000Z",
        rejected: []
      })
    })
    await manager.importRemote({ source: "owner/fresh" })
    writeFileSync(
      join(fixture, "codevisor-plugin.json"),
      JSON.stringify({ ...freshManifest, version: "2.0.0" })
    )

    expect(
      (await manager.listUpdates()).updates.find((item) => item.pluginId === "owner.fresh")
    ).toMatchObject({ pluginId: "owner.fresh", state: "available" })
    const plan = await manager.prepareUpdate("owner.fresh")
    expect(plan).toMatchObject({ resolvedCommit: commit })
    await expect(manager.applyUpdate("owner.fresh", plan.planId)).resolves.toMatchObject({
      id: "owner.fresh",
      version: "2.0.0"
    })
  })

  it("installs successfully even when the plugin immediately fails to start", async () => {
    const fixture = makeFixture(freshManifest)
    const spawn = fakeSpawn({ listen: false })
    const { manager } = makeManager({
      maxConsecutiveFailures: 1,
      ...advancingClock(),
      spawnShell: spawn.spawnShell
    })
    const linked = await manager.link({ path: fixture })
    expect(linked.state).toBe("failed")
  })

  it("rolls back a managed install that never becomes healthy", async () => {
    const fixture = makeFixture(freshManifest)
    const spawn = fakeSpawn({ listen: false })
    const { manager, root } = makeManager({
      clone: async (url, _ref, destination) => {
        await cp(url, destination, { recursive: true })
        return { resolvedCommit: "a".repeat(40) }
      },
      maxConsecutiveFailures: 1,
      ...advancingClock(),
      spawnShell: spawn.spawnShell
    })
    await expect(manager.importRemote({ source: fixture })).rejects.toThrow(
      /did not start listening/
    )
    expect(existsSync(join(root, "owner.fresh"))).toBe(false)
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
    await expect(manager.remove("owner.fresh")).rejects.toThrow(/linked, not managed/)
  })

  it("unlinks a linked plugin without touching its checkout", async () => {
    const fixture = makeFixture(freshManifest)
    const { manager, root } = makeManager()
    await manager.link({ path: fixture })
    const after = await manager.unlink("owner.fresh")
    expect(after.plugins.map((plugin) => plugin.id)).not.toContain("owner.fresh")
    expect(existsSync(join(root, "owner.fresh"))).toBe(false)
    expect(existsSync(fixture)).toBe(true)
  })
})
