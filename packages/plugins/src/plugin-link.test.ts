import { existsSync, mkdirSync, symlinkSync, writeFileSync } from "node:fs"
import { cp } from "node:fs/promises"
import { join } from "node:path"

import { describe, expect, it } from "vitest"

import { makePluginInstaller, type PluginInstallerDeps } from "./plugin-install.js"
import type { ClonePluginSourceResult } from "./plugin-source.js"
import { MANAGED_PLUGIN_MARKER, scanPlugins } from "./plugin-store.js"
import { exampleManifest, makeDir, writePlugin } from "./test-support.js"

/// Nothing here touches the network: the "clone" copies a local fixture.
const copyClone = async (
  url: string,
  _ref: string | undefined,
  destination: string
): Promise<ClonePluginSourceResult> => {
  await cp(url, destination, { recursive: true })
  return { resolvedCommit: "a".repeat(40) }
}

const makeFixture = (manifest: Record<string, unknown>): string => {
  const fixture = makeDir("codevisor-plugin-fixture-")
  writeFileSync(join(fixture, "codevisor-plugin.json"), JSON.stringify(manifest))
  writeFileSync(join(fixture, "server.js"), "// plugin server")
  return fixture
}

const makeInstaller = (
  overrides: Partial<PluginInstallerDeps> = {}
): { installer: ReturnType<typeof makePluginInstaller>; root: string; stopped: Array<string> } => {
  const root = makeDir("codevisor-plugins-root-")
  const stopped: Array<string> = []
  const installer = makePluginInstaller({
    clone: copyClone,
    findExecutable: async (name) => `/usr/bin/${name}`,
    pluginDataRoot: makeDir("codevisor-plugin-data-root-"),
    pluginsRoot: root,
    resolveEnv: async () => ({ PATH: "/usr/bin" }),
    stop: (pluginId) => stopped.push(pluginId),
    verifyInstalled: async () => undefined,
    ...overrides
  })
  return { installer, root, stopped }
}

describe("link", () => {
  it("symlinks a valid local plugin directory into the root", async () => {
    const fixture = makeFixture(exampleManifest)
    const { installer, root } = makeInstaller()
    const manifest = await installer.link({ path: fixture })
    expect(manifest.id).toBe("owner.example")
    const scan = scanPlugins(root)
    expect(scan.plugins[0]?.id).toBe("owner.example")
    expect(scan.plugins[0]?.source).toBe("linked")
  })

  it("validates the path before touching the plugins root", async () => {
    const { installer } = makeInstaller()
    await expect(installer.link({ path: "relative/path" })).rejects.toThrow(/must be absolute/)
    await expect(installer.link({ path: "/nonexistent/plugin" })).rejects.toThrow(/Not a directory/)
    const file = join(makeDir("codevisor-plugin-file-"), "file.txt")
    writeFileSync(file, "not a dir")
    await expect(installer.link({ path: file })).rejects.toThrow(/Not a directory/)
    const empty = makeDir("codevisor-plugin-empty-")
    await expect(installer.link({ path: empty })).rejects.toThrow(/No codevisor-plugin.json/)
  })

  it("conflicts on duplicate ids and occupied destinations", async () => {
    const fixture = makeFixture(exampleManifest)
    const { installer, root } = makeInstaller()
    await installer.link({ path: fixture })
    await expect(installer.link({ path: fixture })).rejects.toThrow(/already installed/)
    // A destination entry the scan does not recognize (no manifest) still
    // blocks the link.
    const other = makeFixture({ ...exampleManifest, id: "owner.other" })
    mkdirSync(join(root, "owner.other"))
    await expect(installer.link({ path: other })).rejects.toThrow(/already exists/)
  })
})

describe("unlink", () => {
  it("removes the link and leaves the developer's checkout untouched", async () => {
    const fixture = makeFixture(exampleManifest)
    const { installer, root } = makeInstaller()
    await installer.link({ path: fixture })

    await installer.unlink("owner.example")

    expect(existsSync(join(root, "owner.example"))).toBe(false)
    // The whole point: the target survives, manifest and all.
    expect(existsSync(join(fixture, "codevisor-plugin.json"))).toBe(true)
    expect(scanPlugins(root).plugins).toHaveLength(0)
  })

  it("refuses a managed install, which uninstall owns", async () => {
    const { installer, root } = makeInstaller()
    mkdirSync(join(root, "owner.example"), { recursive: true })
    writeFileSync(
      join(root, "owner.example", "codevisor-plugin.json"),
      JSON.stringify(exampleManifest)
    )
    writeFileSync(join(root, "owner.example", MANAGED_PLUGIN_MARKER), "")

    await expect(installer.unlink("owner.example")).rejects.toThrow(/not a link/)
    expect(existsSync(join(root, "owner.example"))).toBe(true)
  })

  it("reports an unknown plugin instead of silently succeeding", async () => {
    const { installer } = makeInstaller()
    await expect(installer.unlink("owner.missing")).rejects.toThrow(/not installed/)
  })
})

describe("remove", () => {
  it("deletes managed installs after stopping them", async () => {
    const fixture = makeFixture(exampleManifest)
    const { installer, root, stopped } = makeInstaller()
    await installer.importRemote({ source: fixture })
    await installer.remove("owner.example")
    expect(stopped).toEqual(["owner.example"])
    expect(existsSync(join(root, "owner.example"))).toBe(false)
  })

  it("404s unknown plugins", async () => {
    const { installer } = makeInstaller()
    await expect(installer.remove("owner.ghost")).rejects.toThrow(/not installed/)
  })

  it("never deletes linked plugins — even links whose target carries a marker", async () => {
    const fixture = makeFixture(exampleManifest)
    writeFileSync(join(fixture, MANAGED_PLUGIN_MARKER), "sneaky")
    const { installer, root } = makeInstaller()
    symlinkSync(fixture, join(root, "owner.example"))
    await expect(installer.remove("owner.example")).rejects.toThrow(/linked, not managed/)
    expect(existsSync(join(fixture, "codevisor-plugin.json"))).toBe(true)
    expect(existsSync(join(root, "owner.example"))).toBe(true)
  })

  it("refuses real directories without the managed marker", async () => {
    const { installer, root } = makeInstaller()
    writePlugin(root, "owner.example", exampleManifest)
    await expect(installer.remove("owner.example")).rejects.toThrow(/linked, not managed/)
    expect(existsSync(join(root, "owner.example"))).toBe(true)
  })
})
