import type { PluginManifest, PluginRegistryEntry, PluginRegistryIndex } from "@codevisor/api"
import { writeFileSync } from "node:fs"
import { join } from "node:path"
import { describe, expect, it, vi } from "vitest"
import type { PluginInstaller } from "./plugin-install.js"
import type { PreparedPluginUpdate, PreparePluginUpdateRequest } from "./plugin-install-types.js"
import { PLUGIN_INSTALL_RECEIPT_FILENAME } from "./plugin-receipt.js"
import type { InstalledPlugin } from "./plugin-store.js"
import { makePluginUpdates } from "./plugin-updates.js"
import { makeDir } from "./test-support.js"

const manifest = (
  id: string,
  version: string,
  extra: Record<string, unknown> = {}
): PluginManifest =>
  ({
    id,
    name: id,
    panes: [{ path: "/main/", title: "Main", type: "main" }],
    protocolVersion: 2,
    run: { argv: ["node", "server.js"] },
    version,
    ...extra
  }) as PluginManifest

const installed = (options: {
  readonly id: string
  readonly version: string
  readonly source?: "linked" | "managed"
  readonly tracking?: "registry" | "pinned"
  readonly repo?: string
  readonly receipt?: boolean
  readonly extra?: Record<string, unknown>
}): InstalledPlugin => {
  const path = makeDir("codevisor-plugin-update-installed-")
  const value = manifest(options.id, options.version, options.extra)
  if (options.receipt !== false && options.source !== "linked") {
    writeFileSync(
      join(path, PLUGIN_INSTALL_RECEIPT_FILENAME),
      JSON.stringify({
        installedAt: "2026-08-01T00:00:00.000Z",
        installedVersion: options.version,
        pluginId: options.id,
        resolvedCommit: "a".repeat(40),
        schemaVersion: 1,
        source: {
          kind: options.repo === undefined ? "git" : "github",
          ...(options.repo === undefined ? {} : { repo: options.repo }),
          tracking: options.tracking ?? "registry",
          url:
            options.repo === undefined
              ? "https://example.test/plugin.git"
              : `https://github.com/${options.repo}.git`
        },
        updatedAt: "2026-08-01T00:00:00.000Z"
      })
    )
  }
  return {
    directoryName: options.id,
    id: options.id,
    manifest: value,
    path,
    source: options.source ?? "managed"
  }
}

const entry = (
  id: string,
  version: string,
  extra: Partial<PluginRegistryEntry> = {}
): PluginRegistryEntry => ({
  commit: "b".repeat(40),
  id,
  name: id,
  panes: [{ path: "/main/", title: "Main", type: "main" }],
  protocolVersion: 2,
  pushedAt: "2026-08-20T00:00:00.000Z",
  repo: `${id.split(".")[0]}/plugin`,
  stars: 1,
  version,
  ...extra
})

const index = (entries: ReadonlyArray<PluginRegistryEntry>): PluginRegistryIndex => ({
  entries,
  generatedAt: "2026-08-20T00:00:00.000Z",
  rejected: []
})

interface InstallerHarness {
  readonly applied: Array<PreparedPluginUpdate>
  readonly discarded: Array<PreparedPluginUpdate>
  readonly prepared: Array<PreparePluginUpdateRequest>
  readonly installer: PluginInstaller
  candidate: PreparedPluginUpdate
  applyError?: Error
}

const installerHarness = (
  current: PluginManifest,
  candidateManifest: PluginManifest = manifest(current.id, "2.0.0")
): InstallerHarness => {
  const applied: Array<PreparedPluginUpdate> = []
  const discarded: Array<PreparedPluginUpdate> = []
  const prepared: Array<PreparePluginUpdateRequest> = []
  const harness = {
    applied,
    discarded,
    prepared,
    candidate: {
      directory: "/prepared/plan-1",
      manifest: candidateManifest,
      planId: "plan-1",
      pluginId: current.id,
      previousManifest: current,
      previousResolvedCommit: "a".repeat(40),
      resolvedCommit: "b".repeat(40)
    },
    installer: undefined as unknown as PluginInstaller
  } as InstallerHarness
  const installer: PluginInstaller = {
    applyPreparedUpdate: async (candidate) => {
      applied.push(candidate)
      if (harness.applyError !== undefined) throw harness.applyError
      return candidate.manifest
    },
    discardPreparedUpdate: async (candidate) => {
      discarded.push(candidate)
    },
    discoverRemote: async () => {
      throw new Error("unused")
    },
    importRemote: async () => {
      throw new Error("unused")
    },
    link: async () => {
      throw new Error("unused")
    },
    prepareUpdate: async (request) => {
      prepared.push(request)
      if (request.expectedPluginId === harness.candidate.pluginId) {
        return {
          ...harness.candidate,
          directory: `/prepared/${request.planId}`,
          planId: request.planId
        }
      }
      return {
        ...harness.candidate,
        directory: `/prepared/${request.planId}`,
        manifest: manifest(request.expectedPluginId, harness.candidate.manifest.version),
        planId: request.planId,
        pluginId: request.expectedPluginId,
        previousManifest: manifest(
          request.expectedPluginId,
          harness.candidate.previousManifest.version
        )
      }
    },
    recover: async () => undefined,
    remove: async () => undefined
  }
  Object.assign(harness, { installer })
  return harness
}

describe("plugin update states", () => {
  it("classifies local, legacy, pinned, and incomplete receipts without fetching", async () => {
    const plugins = [
      installed({ id: "acme.linked", source: "linked", version: "1.0.0" }),
      installed({ id: "acme.legacy", receipt: false, version: "1.0.0" }),
      installed({ id: "acme.pinned", repo: "acme/plugin", tracking: "pinned", version: "1.0.0" }),
      installed({ id: "acme.norepo", version: "1.0.0" })
    ]
    const fetchRegistry = vi.fn(async () => index([]))
    const updates = makePluginUpdates({
      fetchRegistry,
      installer: installerHarness(plugins[0]!.manifest).installer,
      listInstalled: () => plugins,
      now: () => Date.parse("2026-08-23T00:00:00.000Z"),
      platform: "darwin"
    })

    expect((await updates.list()).updates).toMatchObject([
      { pluginId: "acme.linked", state: "pinned" },
      { pluginId: "acme.legacy", state: "sourceUnknown" },
      { pluginId: "acme.pinned", state: "pinned" },
      { pluginId: "acme.norepo", state: "checkFailed" }
    ])
    expect(fetchRegistry).not.toHaveBeenCalled()
  })

  it("turns registry failures into per-plugin checkFailed states", async () => {
    const plugin = installed({ id: "acme.one", repo: "acme/plugin", version: "1.0.0" })
    const updates = makePluginUpdates({
      fetchRegistry: () => Promise.reject("offline"),
      installer: installerHarness(plugin.manifest).installer,
      listInstalled: () => [plugin],
      platform: "darwin"
    })
    expect((await updates.list()).updates[0]).toMatchObject({
      reason: "offline",
      state: "checkFailed"
    })

    const unavailable = makePluginUpdates({
      installer: installerHarness(plugin.manifest).installer,
      listInstalled: () => [plugin],
      platform: "darwin"
    })
    expect((await unavailable.list()).updates[0]?.reason).toBe("Plugin registry is unavailable")
  })

  it("uses semantic versions and reports every registry compatibility outcome", async () => {
    const specs = [
      ["acme.same", "1.0.0"],
      ["acme.ahead", "3.0.0"],
      ["acme.available", "1.0.0"],
      ["acme.platform", "1.0.0"],
      ["acme.codevisor", "1.0.0"],
      ["acme.protocol", "1.0.0"],
      ["acme.badcurrent", "latest"],
      ["acme.badnext", "1.0.0"],
      ["acme.badmin", "1.0.0"],
      ["acme.missing", "1.0.0"],
      ["acme.repo", "1.0.0"],
      ["acme.compatible", "1.0.0"]
    ] as const
    const plugins = specs.map(([id, version]) => installed({ id, repo: "acme/plugin", version }))
    const entries = [
      entry("acme.same", "1.0.0"),
      entry("acme.ahead", "2.0.0"),
      entry("acme.available", "2.0.0"),
      entry("acme.platform", "2.0.0", { platforms: ["linux"] }),
      entry("acme.codevisor", "2.0.0", { minCodevisorVersion: "2.0.0" }),
      entry("acme.protocol", "2.0.0", { protocolVersion: 99 }),
      entry("acme.badcurrent", "2.0.0"),
      entry("acme.badnext", "next"),
      entry("acme.badmin", "2.0.0", { minCodevisorVersion: "new" }),
      entry("acme.repo", "2.0.0", { repo: "other/plugin" }),
      entry("acme.compatible", "2.0.0", { minCodevisorVersion: "1.0.0" })
    ]
    const updates = makePluginUpdates({
      codevisorVersion: "1.5.0",
      fetchRegistry: async () => index(entries),
      installer: installerHarness(plugins[0]!.manifest).installer,
      listInstalled: () => plugins,
      platform: "darwin"
    })
    const states = Object.fromEntries(
      (await updates.list()).updates.map((item) => [item.pluginId, item])
    )
    expect(states["acme.same"]?.state).toBe("current")
    expect(states["acme.ahead"]?.state).toBe("current")
    expect(states["acme.available"]?.state).toBe("available")
    expect(states["acme.platform"]).toMatchObject({
      reason: expect.stringContaining("darwin"),
      state: "incompatible"
    })
    expect(states["acme.codevisor"]).toMatchObject({
      reason: expect.stringContaining("requires Codevisor 2.0.0"),
      state: "incompatible"
    })
    expect(states["acme.protocol"]).toMatchObject({
      reason: expect.stringContaining("unsupported"),
      state: "incompatible"
    })
    expect(states["acme.badcurrent"]?.state).toBe("checkFailed")
    expect(states["acme.badnext"]?.state).toBe("checkFailed")
    expect(states["acme.badmin"]).toMatchObject({
      reason: expect.stringContaining("invalid minimum"),
      state: "incompatible"
    })
    expect(states["acme.missing"]?.state).toBe("checkFailed")
    expect(states["acme.repo"]).toMatchObject({
      reason: expect.stringContaining("does not match"),
      state: "checkFailed"
    })
    expect(states["acme.compatible"]?.state).toBe("available")
  })

  it("reports missing or invalid local Codevisor versions", async () => {
    const plugin = installed({ id: "acme.one", repo: "acme/plugin", version: "1.0.0" })
    await Promise.all(
      [undefined, "dev"].map(async (codevisorVersion) => {
        const updates = makePluginUpdates({
          fetchRegistry: async () =>
            index([entry("acme.one", "2.0.0", { minCodevisorVersion: "1.0.0" })]),
          installer: installerHarness(plugin.manifest).installer,
          listInstalled: () => [plugin],
          platform: "darwin",
          ...(codevisorVersion === undefined ? {} : { codevisorVersion })
        })
        expect((await updates.list()).updates[0]).toMatchObject({
          reason: expect.stringContaining("no comparable version"),
          state: "incompatible"
        })
      })
    )
  })
})

describe("prepared plugin update plans", () => {
  const setup = () => {
    const currentManifest = manifest("acme.plugin", "1.0.0", {
      panes: [
        { path: "/main/", title: "Old", type: "main" },
        { path: "/gone/", title: "Gone", type: "gone" }
      ],
      requirements: { executables: [{ name: "node" }] },
      setup: [{ argv: ["npm", "install"] }],
      tools: [
        { description: "Old", name: "shared", path: "/old" },
        { description: "Gone", name: "gone", path: "/gone" }
      ]
    })
    const plugin = installed({ id: "acme.plugin", repo: "acme/plugin", version: "1.0.0" })
    const nextManifest = manifest("acme.plugin", "2.0.0", {
      panes: [
        { path: "/main/", title: "New", type: "main" },
        { path: "/new/", title: "New", type: "new" }
      ],
      setup: [{ argv: ["npm", "ci"] }],
      tools: [
        { description: "New", name: "shared", path: "/new" },
        { description: "New", name: "new", path: "/new" }
      ]
    })
    const harness = installerHarness(currentManifest, nextManifest)
    let time = Date.parse("2026-08-23T00:00:00.000Z")
    let sequence = 0
    const updates = makePluginUpdates({
      codevisorVersion: "1.0.0",
      createPlanId: () => `plan-${++sequence}`,
      fetchRegistry: async () => index([entry("acme.plugin", "2.0.0")]),
      installer: harness.installer,
      listInstalled: () => [plugin],
      now: () => time,
      planTtlMs: 1_000,
      platform: "darwin"
    })
    return { harness, plugin, setTime: (value: number) => (time = value), updates }
  }

  it("prepares an exact commit and describes command, pane, and tool changes", async () => {
    const { harness, updates } = setup()
    const plan = await updates.prepare("acme.plugin")
    expect(harness.prepared[0]).toEqual({
      expectedPluginId: "acme.plugin",
      planId: "plan-1",
      source: `acme/plugin#${"b".repeat(40)}`,
      sourceReceipt: {
        kind: "github",
        repo: "acme/plugin",
        tracking: "registry",
        url: "https://github.com/acme/plugin.git"
      }
    })
    expect(plan).toMatchObject({
      candidate: { runCommand: "node server.js", setupCommands: ["npm ci"], version: "2.0.0" },
      current: { setupCommands: ["npm install"], version: "1.0.0" },
      paneChanges: { added: ["new"], changed: ["main"], removed: ["gone"] },
      planId: "plan-1",
      toolChanges: { added: ["new"], changed: ["shared"], removed: ["gone"] }
    })
    expect(plan.current.requirements).toEqual({ executables: [{ name: "node" }] })
    expect(plan.candidate.requirements).toBeUndefined()
  })

  it("replaces an older plan for the same plugin", async () => {
    const { harness, updates } = setup()
    await updates.prepare("acme.plugin")
    const second = await updates.prepare("acme.plugin")
    expect(second.planId).toBe("plan-2")
    expect(harness.discarded.map((item) => item.planId)).toEqual(["plan-1"])
  })

  it("keeps prepared plans for different plugins independent", async () => {
    const one = installed({ id: "acme.one", repo: "acme/one", version: "1.0.0" })
    const two = installed({ id: "acme.two", repo: "acme/two", version: "1.0.0" })
    const harness = installerHarness(one.manifest)
    let sequence = 0
    const updates = makePluginUpdates({
      createPlanId: () => `multi-${++sequence}`,
      fetchRegistry: async () =>
        index([
          entry("acme.one", "2.0.0", { repo: "acme/one" }),
          entry("acme.two", "2.0.0", { repo: "acme/two" })
        ]),
      installer: harness.installer,
      listInstalled: () => [one, two],
      platform: "darwin"
    })

    const first = await updates.prepare("acme.one")
    const second = await updates.prepare("acme.two")
    expect(first.current.tools).toBeUndefined()
    expect(second.candidate.tools).toBeUndefined()
    expect(harness.discarded).toEqual([])
    await expect(updates.apply("acme.one", first.planId)).resolves.toMatchObject({ id: "acme.one" })
    await expect(updates.apply("acme.two", second.planId)).resolves.toMatchObject({
      id: "acme.two"
    })
  })

  it("rejects missing, current, and registry-inconsistent candidates", async () => {
    const { harness, updates } = setup()
    await expect(updates.prepare("missing.plugin")).rejects.toThrow(/not installed/)

    const current = makePluginUpdates({
      fetchRegistry: async () => index([entry("acme.plugin", "1.0.0")]),
      installer: harness.installer,
      listInstalled: () => [
        installed({ id: "acme.plugin", repo: "acme/plugin", version: "1.0.0" })
      ],
      platform: "darwin"
    })
    await expect(current.prepare("acme.plugin")).rejects.toThrow(/no compatible update/)

    harness.candidate = { ...harness.candidate, resolvedCommit: "c".repeat(40) }
    await expect(updates.prepare("acme.plugin")).rejects.toThrow(/metadata changed/)
    expect(harness.discarded.at(-1)?.resolvedCommit).toBe("c".repeat(40))

    harness.candidate = {
      ...harness.candidate,
      manifest: manifest("acme.plugin", "2.1.0"),
      resolvedCommit: "b".repeat(40)
    }
    await expect(updates.prepare("acme.plugin")).rejects.toThrow(/metadata changed/)
  })

  it("applies plans once and discards bytes after success or failure", async () => {
    const { harness, updates } = setup()
    const plan = await updates.prepare("acme.plugin")
    await expect(updates.apply("other.plugin", plan.planId)).rejects.toThrow(/missing or expired/)
    await expect(updates.apply("acme.plugin", plan.planId)).resolves.toMatchObject({
      version: "2.0.0"
    })
    expect(harness.applied).toHaveLength(1)
    expect(harness.discarded.at(-1)?.planId).toBe(plan.planId)
    await expect(updates.apply("acme.plugin", plan.planId)).rejects.toThrow(/missing or expired/)

    const failingPlan = await updates.prepare("acme.plugin")
    harness.applyError = new Error("verification failed")
    await expect(updates.apply("acme.plugin", failingPlan.planId)).rejects.toThrow(
      /verification failed/
    )
    expect(harness.discarded.at(-1)?.planId).toBe(failingPlan.planId)
  })

  it("expires plans deterministically during the next operation", async () => {
    const { harness, setTime, updates } = setup()
    const plan = await updates.prepare("acme.plugin")
    setTime(Date.parse("2026-08-23T00:00:01.001Z"))
    await updates.list()
    expect(harness.discarded.at(-1)?.planId).toBe(plan.planId)
    await expect(updates.apply("acme.plugin", plan.planId)).rejects.toThrow(/missing or expired/)
  })
})
