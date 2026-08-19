import { existsSync, writeFileSync } from "node:fs"
import { cp } from "node:fs/promises"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import type { PluginStateEvent } from "./plugins-manager.js"
import { exampleManifest, makeDir, makeManager } from "./test-support.js"

/// Manager-level wiring for the install pipeline: the installer runs behind
/// the same facade as the runtime, summaries come from a fresh scan, and list
/// changes fan out as plugin.state.updated events.

const makeFixture = (manifest: Record<string, unknown>): string => {
  const fixture = makeDir("codevisor-plugin-fixture-")
  writeFileSync(join(fixture, "codevisor-plugin.json"), JSON.stringify(manifest))
  return fixture
}

const freshManifest = { ...exampleManifest, id: "owner.fresh", name: "Fresh" }

describe("manager install pipeline", () => {
  it("discovers, imports, and removes a plugin through the facade", async () => {
    const fixture = makeFixture(freshManifest)
    const events: Array<PluginStateEvent> = []
    const { manager, root } = makeManager({
      clone: (url, _ref, destination) => cp(url, destination, { recursive: true }),
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
    expect(discovered.alreadyInstalled).toBe(false)

    const imported = await manager.importRemote({ source: fixture })
    expect(imported.id).toBe("owner.fresh")
    expect(imported.source).toBe("managed")
    expect(imported.state).toBe("stopped")
    expect(events.some((event) => event.subjectId === "owner.fresh")).toBe(true)
    expect(existsSync(join(root, "owner.fresh"))).toBe(true)

    const afterRemove = await manager.remove("owner.fresh")
    expect(afterRemove.plugins.map((plugin) => plugin.id)).toEqual(["owner.example"])
    expect(existsSync(join(root, "owner.fresh"))).toBe(false)
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
