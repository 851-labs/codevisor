import type { PluginManifestV2 } from "@codevisor/api"
import { existsSync, readFileSync, writeFileSync } from "node:fs"
import { cp } from "node:fs/promises"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import { makePluginInstaller, type PluginInstallerDeps } from "./plugin-install.js"
import { PLUGIN_INSTALL_RECEIPT_FILENAME, readPluginInstallReceipt } from "./plugin-receipt.js"
import { MANAGED_PLUGIN_MARKER, MANAGED_PLUGIN_MARKER_CONTENT } from "./plugin-store.js"
import type { PluginProcessHandle, PluginSpawnOptions } from "./plugin-supervisor.js"
import { makeDir } from "./test-support.js"

const manifest = (id: string, version: string, setup = false): PluginManifestV2 => ({
  id,
  name: id,
  panes: [{ path: "/main/", title: "Main", type: "main" }],
  protocolVersion: 2,
  run: { argv: ["node", "server.js"] },
  ...(setup ? { setup: [{ argv: ["npm", "ci"] }] } : {}),
  version
})

const fixture = (value: PluginManifestV2): string => {
  const path = makeDir("codevisor-prepared-update-source-")
  writeFileSync(join(path, "codevisor-plugin.json"), JSON.stringify(value))
  writeFileSync(join(path, "server.js"), value.version)
  return path
}

const successfulSetup =
  (): NonNullable<PluginInstallerDeps["spawnArgv"]> =>
  (_argv: ReadonlyArray<string>, options: PluginSpawnOptions): PluginProcessHandle => {
    writeFileSync(join(options.cwd, "built.txt"), options.env["CODEVISOR_PLUGIN_VERSION"] ?? "")
    const listeners: Array<(message: string, code: number) => void> = []
    setImmediate(() => {
      for (const listener of listeners) listener("done", 0)
    })
    return { kill: () => undefined, onExit: (listener) => listeners.push(listener), pid: 1 }
  }

const harness = (candidateSource: string) => {
  const root = makeDir("codevisor-prepared-update-root-")
  const stopped: Array<string> = []
  const verified: Array<string> = []
  const installer = makePluginInstaller({
    clone: async (_url, ref, destination) => {
      await cp(candidateSource, destination, { recursive: true })
      return { resolvedCommit: ref ?? "a".repeat(40) }
    },
    findExecutable: async (name) => `/usr/bin/${name}`,
    pluginDataRoot: makeDir("codevisor-prepared-update-data-"),
    pluginsRoot: root,
    resolveEnv: async () => ({ PATH: "/usr/bin" }),
    spawnArgv: successfulSetup(),
    stop: (pluginId) => stopped.push(pluginId),
    verifyInstalled: async (pluginId) => {
      verified.push(pluginId)
    }
  })
  return { installer, root, stopped, verified }
}

const request = (planId = "plan-1") => ({
  expectedPluginId: "owner.example",
  planId,
  source: `owner/plugin#${"b".repeat(40)}`,
  sourceReceipt: {
    kind: "github" as const,
    repo: "owner/plugin",
    tracking: "registry" as const,
    url: "https://github.com/owner/plugin.git"
  }
})

describe("prepared plugin update installation", () => {
  it("keeps the old plugin live, then applies the exact prepared bytes", async () => {
    const source = fixture(manifest("owner.example", "1.0.0"))
    const world = harness(source)
    await world.installer.importRemote({ source })
    world.stopped.splice(0)
    world.verified.splice(0)
    writeFileSync(
      join(source, "codevisor-plugin.json"),
      JSON.stringify(manifest("owner.example", "2.0.0", true))
    )
    writeFileSync(join(source, "server.js"), "2.0.0")

    const prepared = await world.installer.prepareUpdate(request())
    expect(world.stopped).toEqual([])
    expect(readFileSync(join(world.root, "owner.example", "server.js"), "utf8")).toBe("1.0.0")
    expect(readFileSync(join(prepared.directory, "built.txt"), "utf8")).toBe("2.0.0")

    // Mutating the source after review cannot affect apply: the plan owns its
    // staged bytes and no clone occurs during this step.
    writeFileSync(join(source, "server.js"), "unreviewed")
    const applied = await world.installer.applyPreparedUpdate(prepared)
    expect(applied.version).toBe("2.0.0")
    expect(readFileSync(join(world.root, "owner.example", "server.js"), "utf8")).toBe("2.0.0")
    expect(world.stopped).toEqual(["owner.example"])
    expect(world.verified).toEqual(["owner.example"])
    expect(readPluginInstallReceipt(join(world.root, "owner.example"))).toMatchObject({
      installedVersion: "2.0.0",
      resolvedCommit: "b".repeat(40),
      source: { repo: "owner/plugin", tracking: "registry" }
    })
    await world.installer.discardPreparedUpdate(prepared)
  })

  it("rejects stale installed versions and receipts", async () => {
    const source = fixture(manifest("owner.example", "1.0.0"))
    const world = harness(source)
    await world.installer.importRemote({ source })
    writeFileSync(
      join(source, "codevisor-plugin.json"),
      JSON.stringify(manifest("owner.example", "2.0.0"))
    )
    const staleVersion = await world.installer.prepareUpdate(request("version-plan"))
    writeFileSync(
      join(world.root, "owner.example", "codevisor-plugin.json"),
      JSON.stringify(manifest("owner.example", "1.1.0"))
    )
    await expect(world.installer.applyPreparedUpdate(staleVersion)).rejects.toThrow(/changed after/)
    await world.installer.discardPreparedUpdate(staleVersion)

    writeFileSync(
      join(world.root, "owner.example", "codevisor-plugin.json"),
      JSON.stringify(manifest("owner.example", "1.0.0"))
    )
    const staleReceipt = await world.installer.prepareUpdate(request("receipt-plan"))
    const receiptPath = join(world.root, "owner.example", PLUGIN_INSTALL_RECEIPT_FILENAME)
    const receipt = JSON.parse(readFileSync(receiptPath, "utf8")) as Record<string, unknown>
    writeFileSync(receiptPath, JSON.stringify({ ...receipt, resolvedCommit: "c".repeat(40) }))
    await expect(world.installer.applyPreparedUpdate(staleReceipt)).rejects.toThrow(/changed after/)
  })

  it("rejects mismatched ids, missing installs, missing receipts, and invalid plan ids", async () => {
    const wrongSource = fixture(manifest("owner.other", "2.0.0"))
    const wrong = harness(wrongSource)
    await expect(wrong.installer.prepareUpdate(request())).rejects.toThrow(/provided manifest id/)

    const source = fixture(manifest("owner.example", "2.0.0"))
    const missing = harness(source)
    await expect(missing.installer.prepareUpdate(request())).rejects.toThrow(/not installed/)

    const legacy = harness(source)
    const destination = join(legacy.root, "owner.example")
    await cp(source, destination, { recursive: true })
    writeFileSync(join(destination, MANAGED_PLUGIN_MARKER), MANAGED_PLUGIN_MARKER_CONTENT)
    await expect(legacy.installer.prepareUpdate(request())).rejects.toThrow(
      /no trusted install receipt/
    )

    const currentSource = fixture(manifest("owner.example", "1.0.0"))
    const invalid = harness(currentSource)
    await invalid.installer.importRemote({ source: currentSource })
    writeFileSync(
      join(currentSource, "codevisor-plugin.json"),
      JSON.stringify(manifest("owner.example", "2.0.0"))
    )
    await expect(invalid.installer.prepareUpdate(request("bad/id"))).rejects.toThrow(
      /Invalid plugin update plan id/
    )
  })

  it("rejects untrusted or missing plan directories and clears plans during recovery", async () => {
    const source = fixture(manifest("owner.example", "1.0.0"))
    const world = harness(source)
    await world.installer.importRemote({ source })
    writeFileSync(
      join(source, "codevisor-plugin.json"),
      JSON.stringify(manifest("owner.example", "2.0.0"))
    )
    const prepared = await world.installer.prepareUpdate(request())
    const untrusted = { ...prepared, directory: makeDir("untrusted-plugin-plan-") }
    await expect(world.installer.applyPreparedUpdate(untrusted)).rejects.toThrow(/not trusted/)
    await expect(world.installer.discardPreparedUpdate(untrusted)).rejects.toThrow(/not trusted/)

    await world.installer.discardPreparedUpdate(prepared)
    await expect(world.installer.applyPreparedUpdate(prepared)).rejects.toThrow(
      /missing or expired/
    )

    const abandoned = await world.installer.prepareUpdate(request("abandoned"))
    expect(existsSync(abandoned.directory)).toBe(true)
    await world.installer.recover()
    expect(existsSync(abandoned.directory)).toBe(false)
  })
})
