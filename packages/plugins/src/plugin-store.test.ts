import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterEach, describe, expect, it } from "vitest"
import {
  MANAGED_PLUGIN_MARKER,
  defaultPluginsRoot,
  findPluginOrFail,
  scanPlugins
} from "./plugin-store.js"
import { writePluginInstallReceipt, type PluginInstallReceipt } from "./plugin-receipt.js"
import { PluginsError } from "./plugins-error.js"

const roots: Array<string> = []

const makeRoot = (): string => {
  const root = mkdtempSync(join(tmpdir(), "codevisor-plugins-test-"))
  roots.push(root)
  return root
}

afterEach(() => {
  for (const root of roots.splice(0)) {
    rmSync(root, { force: true, recursive: true })
  }
})

const writePlugin = (root: string, directoryName: string, id: string): string => {
  const path = join(root, directoryName)
  mkdirSync(path, { recursive: true })
  writeFileSync(
    join(path, "codevisor-plugin.json"),
    JSON.stringify({
      id,
      name: directoryName,
      panes: [{ path: "/panes/main/", title: "Main", type: "main" }],
      protocolVersion: 1,
      run: { command: "bun run start" },
      version: "0.1.0"
    })
  )
  return path
}

describe("scanPlugins", () => {
  it("returns empty results for a missing root", () => {
    const scan = scanPlugins(join(tmpdir(), "does-not-exist-codevisor"))
    expect(scan.plugins).toHaveLength(0)
    expect(scan.invalid).toHaveLength(0)
  })

  it("discovers plugins and classifies managed vs linked", () => {
    const root = makeRoot()
    writePlugin(root, "linked-plugin", "owner.linked")
    const managedPath = writePlugin(root, "managed-plugin", "owner.managed")
    writeFileSync(join(managedPath, MANAGED_PLUGIN_MARKER), "")
    const scan = scanPlugins(root)
    expect(scan.plugins.map((plugin) => [plugin.id, plugin.source])).toEqual([
      ["owner.linked", "linked"],
      ["owner.managed", "managed"]
    ])
  })

  it("attaches valid managed-install provenance and ignores mismatched receipts", async () => {
    const root = makeRoot()
    const managedPath = writePlugin(root, "managed-plugin", "owner.managed")
    writeFileSync(join(managedPath, MANAGED_PLUGIN_MARKER), "")
    const receipt: PluginInstallReceipt = {
      installedAt: "2026-08-23T12:00:00.000Z",
      installedVersion: "0.1.0",
      pluginId: "owner.managed",
      resolvedCommit: "a".repeat(40),
      schemaVersion: 1,
      source: {
        kind: "github",
        repo: "owner/managed",
        tracking: "registry",
        url: "https://github.com/owner/managed.git"
      },
      updatedAt: "2026-08-23T12:00:00.000Z"
    }
    await writePluginInstallReceipt(managedPath, receipt)
    expect(scanPlugins(root).plugins[0]?.receipt).toEqual(receipt)
    await writePluginInstallReceipt(managedPath, { ...receipt, pluginId: "owner.other" })
    expect(scanPlugins(root).plugins[0]?.receipt).toBeUndefined()
  })

  it("resolves symlinked plugin directories", () => {
    const root = makeRoot()
    const external = mkdtempSync(join(tmpdir(), "codevisor-plugin-dev-"))
    roots.push(external)
    writePlugin(external, "dev", "owner.dev")
    symlinkSync(join(external, "dev"), join(root, "dev"))
    const scan = scanPlugins(root)
    expect(scan.plugins.map((plugin) => plugin.id)).toEqual(["owner.dev"])
    expect(scan.plugins[0]?.source).toBe("linked")
  })

  it("skips dot entries and plain files", () => {
    const root = makeRoot()
    writeFileSync(join(root, ".DS_Store"), "")
    writeFileSync(join(root, "notes.txt"), "")
    const scan = scanPlugins(root)
    expect(scan.plugins).toHaveLength(0)
    expect(scan.invalid).toHaveLength(0)
  })

  it("reports broken symlinks without aborting the scan", () => {
    const root = makeRoot()
    symlinkSync(join(root, "missing-target"), join(root, "broken"))
    writePlugin(root, "ok", "owner.ok")
    const scan = scanPlugins(root)
    expect(scan.plugins.map((plugin) => plugin.id)).toEqual(["owner.ok"])
    expect(scan.invalid).toEqual([
      { directoryName: "broken", message: "Unreadable entry (broken symlink?)" }
    ])
  })

  it("reports directories without a manifest", () => {
    const root = makeRoot()
    mkdirSync(join(root, "empty"))
    const scan = scanPlugins(root)
    expect(scan.invalid[0]?.message).toContain("Missing codevisor-plugin.json")
  })

  it("reports invalid manifests", () => {
    const root = makeRoot()
    const path = join(root, "bad")
    mkdirSync(path)
    writeFileSync(join(path, "codevisor-plugin.json"), "{}")
    const scan = scanPlugins(root)
    expect(scan.invalid[0]?.message).toContain("Invalid plugin manifest")
  })

  it("rejects duplicate plugin ids, first directory wins", () => {
    const root = makeRoot()
    writePlugin(root, "a-first", "owner.dupe")
    writePlugin(root, "b-second", "owner.dupe")
    const scan = scanPlugins(root)
    expect(scan.plugins).toHaveLength(1)
    expect(scan.plugins[0]?.directoryName).toBe("a-first")
    expect(scan.invalid[0]?.message).toContain("Duplicate plugin id")
  })

  it("defaults the root under the home directory", () => {
    expect(defaultPluginsRoot()).toContain(".codevisor")
  })

  it("honors the CODEVISOR_PLUGINS_ROOT override", () => {
    const root = makeRoot()
    process.env["CODEVISOR_PLUGINS_ROOT"] = root
    try {
      expect(defaultPluginsRoot()).toBe(root)
    } finally {
      delete process.env["CODEVISOR_PLUGINS_ROOT"]
    }
  })
})

describe("findPluginOrFail", () => {
  it("returns the plugin when installed", () => {
    const root = makeRoot()
    writePlugin(root, "here", "owner.here")
    const scan = scanPlugins(root)
    expect(findPluginOrFail(scan, "owner.here").id).toBe("owner.here")
  })

  it("throws notFound otherwise", () => {
    try {
      findPluginOrFail({ invalid: [], plugins: [] }, "owner.gone")
      expect.unreachable("should have thrown")
    } catch (cause) {
      expect(cause).toBeInstanceOf(PluginsError)
      expect((cause as PluginsError).code).toBe("notFound")
    }
  })
})
