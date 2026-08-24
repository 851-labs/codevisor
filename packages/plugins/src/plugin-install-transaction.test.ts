import { existsSync, readFileSync, writeFileSync } from "node:fs"
import { cp } from "node:fs/promises"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import { makePluginInstaller, type PluginInstallerDeps } from "./plugin-install.js"
import { readPluginInstallReceipt } from "./plugin-receipt.js"
import type { PluginProcessHandle, PluginSpawnOptions } from "./plugin-supervisor.js"
import { exampleManifest, makeDir } from "./test-support.js"

const cloneFixture: NonNullable<PluginInstallerDeps["clone"]> = async (url, _ref, destination) => {
  await cp(url, destination, { recursive: true })
  return { resolvedCommit: "a".repeat(40) }
}

interface SetupSpawn {
  readonly calls: Array<{ readonly env: NodeJS.ProcessEnv }>
  readonly spawn: (command: string, options: PluginSpawnOptions) => PluginProcessHandle
}

const setupSpawn = (exitCode: number): SetupSpawn => {
  const calls: SetupSpawn["calls"] = []
  return {
    calls,
    spawn: (_command, options) => {
      calls.push({ env: options.env })
      const listeners: Array<(message: string, code: number) => void> = []
      setImmediate(() => {
        for (const listener of listeners) listener("setup finished", exitCode)
      })
      return { kill: () => undefined, onExit: (listener) => listeners.push(listener), pid: 1 }
    }
  }
}

const manifestFixture = (manifest: Record<string, unknown>): string => {
  const directory = makeDir("codevisor-plugin-transaction-fixture-")
  writeFileSync(join(directory, "codevisor-plugin.json"), JSON.stringify(manifest))
  return directory
}

const installerFixture = (
  overrides: Partial<PluginInstallerDeps> = {}
): {
  readonly installer: ReturnType<typeof makePluginInstaller>
  readonly root: string
  readonly stopped: Array<string>
} => {
  const root = makeDir("codevisor-plugin-transaction-root-")
  const stopped: Array<string> = []
  return {
    installer: makePluginInstaller({
      clone: cloneFixture,
      findExecutable: async (name) => `/usr/bin/${name}`,
      pluginDataRoot: makeDir("codevisor-plugin-transaction-data-"),
      pluginsRoot: root,
      resolveEnv: async () => ({ PATH: "/usr/bin" }),
      stop: (pluginId) => stopped.push(pluginId),
      verifyInstalled: async () => undefined,
      ...overrides
    }),
    root,
    stopped
  }
}

describe("transactional plugin preparation", () => {
  it("leaves an installed plugin running and untouched when update setup fails", async () => {
    const source = manifestFixture(exampleManifest)
    const setup = setupSpawn(1)
    const { installer, root, stopped } = installerFixture({ spawnShell: setup.spawn })
    await installer.importRemote({ source })
    writeFileSync(join(root, "owner.example", "old.txt"), "still here")
    writeFileSync(
      join(source, "codevisor-plugin.json"),
      JSON.stringify({
        ...exampleManifest,
        install: { command: "failing setup" },
        version: "0.2.0"
      })
    )

    await expect(installer.importRemote({ source })).rejects.toThrow(/setup command failed/)
    expect(readFileSync(join(root, "owner.example", "old.txt"), "utf8")).toBe("still here")
    expect(stopped).toEqual([])
  })

  it("rejects setup that changes the reviewed manifest", async () => {
    const source = manifestFixture({
      ...exampleManifest,
      install: { command: "rewrite manifest" }
    })
    const successful = setupSpawn(0)
    const { installer, root } = installerFixture({
      spawnShell: (command, options) => {
        writeFileSync(
          join(options.cwd, "codevisor-plugin.json"),
          JSON.stringify({ ...exampleManifest, version: "9.9.9" })
        )
        return successful.spawn(command, options)
      }
    })
    await expect(installer.importRemote({ source })).rejects.toThrow(
      /setup changed codevisor-plugin\.json/
    )
    expect(existsSync(join(root, "owner.example"))).toBe(false)
  })

  it("updates in place while preserving receipt history and setup context", async () => {
    const source = manifestFixture(exampleManifest)
    const times = [new Date("2026-08-01T00:00:00Z"), new Date("2026-08-02T00:00:00Z")]
    const setup = setupSpawn(0)
    const { installer, root, stopped } = installerFixture({
      receiptNow: () => times.shift() as Date,
      spawnShell: setup.spawn
    })
    await installer.importRemote({ source })
    const originalReceipt = readPluginInstallReceipt(join(root, "owner.example"))
    writeFileSync(join(root, "owner.example", "stale.txt"), "old")
    writeFileSync(
      join(source, "codevisor-plugin.json"),
      JSON.stringify({
        ...exampleManifest,
        install: { command: "prepare update" },
        version: "0.2.0"
      })
    )

    const updated = await installer.importRemote({ source })

    expect(updated.version).toBe("0.2.0")
    expect(stopped).toEqual(["owner.example"])
    expect(existsSync(join(root, "owner.example", "stale.txt"))).toBe(false)
    expect(readFileSync(join(root, "owner.example", "codevisor-plugin.json"), "utf8")).toContain(
      "0.2.0"
    )
    expect(readPluginInstallReceipt(join(root, "owner.example"))).toMatchObject({
      installedAt: originalReceipt?.installedAt,
      installedVersion: "0.2.0",
      updatedAt: "2026-08-02T00:00:00.000Z"
    })
    expect(setup.calls[0]?.env).toMatchObject({
      CODEVISOR_PLUGIN_INSTALL_REASON: "update",
      CODEVISOR_PLUGIN_PREVIOUS_VERSION: "0.1.0",
      CODEVISOR_PLUGIN_VERSION: "0.2.0"
    })
  })
})
