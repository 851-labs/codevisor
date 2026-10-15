import { mkdtemp } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { decode } from "@codevisor/api"
import type { HarnessAuthManager } from "@codevisor/harness-manager"
import { writePluginInstallReceipt } from "@codevisor/plugins"
import { makeSkillStore } from "@codevisor/skills"
import { makeBlobStore } from "@codevisor/sync"
import { Schema } from "effect"
import { describe, expect, it, vi } from "vitest"

import { defaultServerConfig } from "../server-config.js"
import {
  makeEventFanout,
  type CodevisorServerConfig,
  type CodevisorServerServices
} from "../server-context.js"
import {
  jsonRequest,
  makeServices,
  pluginSummary,
  run,
  startWithApp,
  tempDirs
} from "../test-support.js"
import { fakeHarnessAuth, fakePlugins } from "./harness-auth-test-support.js"
import { field } from "./response-test-support.js"
import {
  makeAuthSyncRefreshScheduler,
  refreshHarnessReadiness,
  refreshMcpReadiness,
  refreshPluginReadiness,
  republishAccountsRoster
} from "./sync-readiness.js"
import {
  configMutationNamespace,
  reconcileForNamespace,
  runBackgroundSyncReconcile
} from "./sync-reconcilers.js"

const config: CodevisorServerConfig = defaultServerConfig({ bootId: "test-boot", id: "server-x" })

const EntryKeys = Schema.Array(Schema.Struct({ key: Schema.String }))

describe("configMutationNamespace", () => {
  it("maps config mutations to their plane and ignores everything else", () => {
    expect(configMutationNamespace("POST", "/v1/mcps")).toBe("mcps")
    expect(configMutationNamespace("PATCH", "/v1/mcps/abc")).toBe("mcps")
    expect(configMutationNamespace("POST", "/v1/native-mcps/import")).toBe("mcps")
    expect(configMutationNamespace("POST", "/v1/skills")).toBe("skills")
    expect(configMutationNamespace("PATCH", "/v1/harnesses/claude")).toBe("harnesses")
    expect(configMutationNamespace("POST", "/v1/plugins/import-remote")).toBe("plugins")
    expect(configMutationNamespace("DELETE", "/v1/plugins/acme.tunes")).toBe("plugins")

    expect(configMutationNamespace("GET", "/v1/mcps")).toBeUndefined()
    expect(configMutationNamespace("HEAD", "/v1/skills")).toBeUndefined()
    expect(configMutationNamespace("OPTIONS", "/v1/plugins")).toBeUndefined()
    expect(configMutationNamespace(undefined, "/v1/mcps")).toBeUndefined()

    expect(configMutationNamespace("POST", "/v1/plugins/x/app/api")).toBeUndefined()
    expect(configMutationNamespace("POST", "/v1/plugins/x/panes/p/token")).toBeUndefined()
    expect(configMutationNamespace("POST", "/v1/plugins/x/tools/run")).toBeUndefined()

    expect(configMutationNamespace("POST", "/v1/sessions")).toBeUndefined()
  })
})

describe("runBackgroundSyncReconcile", () => {
  it("publishes local state into the replica after a mutation", async () => {
    const { services } = await makeServices("server-bg")
    const fanout = await run(makeEventFanout)
    await services.mcp?.create({
      authType: "none",
      enabled: false,
      name: "Background",
      transport: "http",
      url: "https://background.example.com/mcp"
    })

    await runBackgroundSyncReconcile(services, config, fanout, "mcps")

    const entries = await run(services.db.getSyncEntries("mcps"))
    expect(entries.map((entry) => entry.key)).toEqual(["Background"])
  })

  it("ignores a legacy opt-out, skips absent services, and swallows failures", async () => {
    const fanout = await run(makeEventFanout)

    const { services: legacy } = await makeServices("server-bg-legacy")
    await run(
      legacy.db.mergeSyncEntries("local.sync", [
        {
          key: "enabled",
          value: false,
          timestamp: { wallMs: 1, counter: 0, deviceId: "z" }
        }
      ])
    )
    await legacy.mcp?.create({
      authType: "none",
      enabled: false,
      name: "Replicated",
      transport: "http",
      url: "https://replicated.example.com/mcp"
    })
    await runBackgroundSyncReconcile(legacy, config, fanout, "mcps")
    expect((await run(legacy.db.getSyncEntries("mcps"))).map((entry) => entry.key)).toEqual([
      "Replicated"
    ])

    const { services: bare } = await makeServices("server-bg-bare")
    await runBackgroundSyncReconcile(bare, config, fanout, "skills")
    expect(await run(bare.db.getSyncEntries("codevisor-skills"))).toEqual([])

    const { services: broken } = await makeServices("server-bg-broken")
    const throwing: CodevisorServerServices = {
      ...broken,
      mcp: { ...broken.mcp, list: () => Promise.reject(new Error("boom")) }
    }
    await expect(
      runBackgroundSyncReconcile(throwing, config, fanout, "mcps")
    ).resolves.toBeUndefined()
  })

  it("publishes the skill store to the fleet after a skills pass", async () => {
    const { services } = await makeServices("server-bg-skills")
    const fanout = await run(makeEventFanout)
    const home = await mkdtemp(join(tmpdir(), "skills-home-"))
    const blobDir = await mkdtemp(join(tmpdir(), "sync-blobs-"))
    tempDirs.push(home, blobDir)
    const skills = makeSkillStore({ dir: join(home, "skills") })
    await skills.create({ name: "Deploy", description: "ship it" })

    await runBackgroundSyncReconcile(
      { ...services, skills, syncBlobs: makeBlobStore(blobDir) },
      config,
      fanout,
      "skills"
    )

    const replica = await run(services.db.getSyncEntries("codevisor-skills"))
    expect(replica.map((entry) => entry.key)).toEqual(["deploy"])
  })

  it("fires end to end from a config mutation over HTTP", async () => {
    const { services } = await makeServices("server-bg-http")
    const fanout = await run(makeEventFanout)
    await services.mcp?.create({
      authType: "none",
      enabled: false,
      name: "Seeded",
      transport: "http",
      url: "https://seeded.example.com/mcp"
    })
    const reconciled = Promise.withResolvers<ReadonlyArray<string>>()
    const unsubscribe = fanout.subscribe((event) => {
      if (event.kind === "sync.changed" && event.subjectId === "mcps") {
        const entries = decode(EntryKeys)(field(event.payload, "entries"))
        reconciled.resolve(entries.map((entry) => entry.key).toSorted())
      }
    })
    const server = await startWithApp(services, fanout)

    const rejected = await jsonRequest(server, "/v1/mcps", {
      body: JSON.stringify({ nope: true }),
      method: "POST"
    })
    expect(rejected.status).toBeGreaterThanOrEqual(400)

    const created = await jsonRequest(server, "/v1/mcps", {
      body: JSON.stringify({
        authType: "none",
        enabled: false,
        name: "Imported",
        transport: "http",
        url: "https://imported.example.com/mcp"
      }),
      method: "POST"
    })
    expect(created.status).toBeLessThan(300)

    expect(await reconciled.promise).toEqual(["Imported", "Seeded"])
    unsubscribe()
  })
})

describe("refreshMcpReadiness", () => {
  it("skips machines without MCP services and swallows publish failures", async () => {
    const fanout = await run(makeEventFanout)
    const { services } = await makeServices("server-x")

    const { mcp: omitted, ...withoutMcp } = services
    void omitted
    await refreshMcpReadiness(withoutMcp, config, fanout)
    expect(await run(services.db.getSyncEntries("mcp-readiness"))).toEqual([])

    const poisoned: CodevisorServerServices = {
      ...services,
      mcp: { ...services.mcp, list: () => Promise.reject(new Error("boom")) }
    }
    await expect(refreshMcpReadiness(poisoned, config, fanout)).resolves.toBeUndefined()
  })
})

describe("auth-derived sync refresh", () => {
  it("derives readiness from stored auth state without starting a passive probe", async () => {
    const fanout = await run(makeEventFanout)
    const { services } = await makeServices("server-auth-readiness")
    const decorateHarnesses = vi.fn<HarnessAuthManager["decorateHarnesses"]>(
      async (harnesses) => harnesses
    )
    const decorateHarnessesFromStoredState = vi.fn<
      HarnessAuthManager["decorateHarnessesFromStoredState"]
    >(async (harnesses) => harnesses)
    const withAuth: CodevisorServerServices = {
      ...services,
      auth: fakeHarnessAuth({ decorateHarnesses, decorateHarnessesFromStoredState })
    }

    await refreshHarnessReadiness(withAuth, config, fanout)

    expect(decorateHarnessesFromStoredState).toHaveBeenCalledTimes(1)
    expect(decorateHarnesses).not.toHaveBeenCalled()
  })

  it("coalesces event bursts into one active refresh and one trailing refresh", async () => {
    const fanout = await run(makeEventFanout)
    const { services } = await makeServices("server-auth-coalescing")
    const firstRefreshGate = Promise.withResolvers<void>()
    const firstStarted = Promise.withResolvers<void>()
    const trailingStarted = Promise.withResolvers<void>()
    const decorateHarnessesFromStoredState = vi.fn<
      HarnessAuthManager["decorateHarnessesFromStoredState"]
    >(async (harnesses) => {
      if (decorateHarnessesFromStoredState.mock.calls.length === 1) {
        firstStarted.resolve()
        await firstRefreshGate.promise
      } else trailingStarted.resolve()
      return harnesses
    })
    const withAuth: CodevisorServerServices = {
      ...services,
      auth: fakeHarnessAuth({
        decorateHarnesses: vi.fn(async (harnesses) => harnesses),
        decorateHarnessesFromStoredState
      })
    }
    const scheduler = makeAuthSyncRefreshScheduler(withAuth, config, fanout)

    for (let index = 0; index < 64; index += 1) scheduler.request()
    await firstStarted.promise
    expect(decorateHarnessesFromStoredState).toHaveBeenCalledTimes(1)

    for (let index = 0; index < 64; index += 1) scheduler.request()
    firstRefreshGate.resolve()
    await trailingStarted.promise
    expect(decorateHarnessesFromStoredState).toHaveBeenCalledTimes(2)

    scheduler.close()
    scheduler.request()
    expect(decorateHarnessesFromStoredState).toHaveBeenCalledTimes(2)
  })
})

describe("refreshPluginReadiness", () => {
  it("derives every row state", async () => {
    const fanout = await run(makeEventFanout)
    const { services } = await makeServices("server-pr")

    const managedPath = await mkdtemp(join(tmpdir(), "codevisor-pr-"))
    await writePluginInstallReceipt(managedPath, {
      installedAt: "2026-01-01T00:00:00.000Z",
      installedVersion: "0.1.0",
      pluginId: "owner.example",
      resolvedCommit: "a".repeat(40),
      schemaVersion: 1,
      source: { kind: "github", repo: "owner/example", tracking: "registry", url: "owner/example" },
      updatedAt: "2026-01-01T00:00:00.000Z"
    })
    const manager = fakePlugins({
      list: async () => ({
        plugins: [
          {
            ...pluginSummary,
            enabled: true,
            id: "owner.example",
            path: managedPath,
            source: "managed"
          },
          {
            ...pluginSummary,
            enabled: false,
            id: "owner.paused",
            path: managedPath,
            source: "managed"
          },
          {
            ...pluginSummary,
            enabled: true,
            id: "dev-linked",
            path: "/tmp/nowhere",
            source: "linked"
          }
        ]
      })
    })

    await run(
      services.db.mergeSyncEntries("plugins", [
        {
          key: "fleet.pending",
          timestamp: { counter: 0, deviceId: "other", wallMs: 1 },
          value: { enabled: true, source: "o/p" }
        },
        {
          key: "fleet.ffmpeg",
          timestamp: { counter: 1, deviceId: "other", wallMs: 1 },
          value: { enabled: true, source: "o/f" }
        },
        {
          deleted: true,
          key: "fleet.gone",
          timestamp: { counter: 2, deviceId: "other", wallMs: 1 },
          value: null
        }
      ])
    )
    await refreshPluginReadiness(services, config, fanout, manager, [
      { id: "fleet.ffmpeg", reason: "needs ffmpeg" }
    ])
    const entries = await run(services.db.getSyncEntries("plugin-readiness"))
    const value = decode(
      Schema.Struct({
        plugins: Schema.Array(
          Schema.Struct({
            id: Schema.String,
            state: Schema.String,
            reason: Schema.optional(Schema.String)
          })
        )
      })
    )(entries[0]?.value)
    const byId = Object.fromEntries(value.plugins.map((row) => [row.id, row]))
    expect(byId["owner.example"]?.state).toBe("ready")
    expect(byId["owner.paused"]?.state).toBe("disabled")
    expect(byId["dev-linked"]?.state).toBe("machineOnly")
    expect(byId["fleet.pending"]?.state).toBe("notInstalled")
    expect(byId["fleet.ffmpeg"]).toEqual({
      id: "fleet.ffmpeg",
      reason: "needs ffmpeg",
      state: "blocked"
    })
    expect(byId["fleet.gone"]).toBeUndefined()

    const poisoned = fakePlugins({ list: () => Promise.reject(new Error("boom")) })
    await expect(
      refreshPluginReadiness(services, config, fanout, poisoned, [])
    ).resolves.toBeUndefined()
  })
})

describe("republishAccountsRoster", () => {
  it("publishes account-state changes into the roster, best-effort", async () => {
    const fanout = await run(makeEventFanout)
    const { services } = await makeServices("server-x")
    await run(
      services.db.saveHarnessAccount({
        authState: "authenticated",
        canLogin: true,
        canLogout: true,
        harnessId: "claude-code",
        label: "Personal",
        profileKind: "default"
      })
    )
    await republishAccountsRoster(services, config, fanout)
    const entries = await run(services.db.getSyncEntries("harness-accounts"))
    expect(entries).toHaveLength(1)
    const value = decode(
      Schema.Struct({ accounts: Schema.Array(Schema.Struct({ authState: Schema.String })) })
    )(entries[0]?.value)
    expect(value.accounts[0]?.authState).toBe("authenticated")

    await republishAccountsRoster(services, config, fanout)
    expect(await run(services.db.getSyncEntries("harness-accounts"))).toHaveLength(1)
    const poisoned: CodevisorServerServices = {
      ...services,
      db: {
        ...services.db,
        getSyncEntries: () => {
          throw new Error("boom")
        }
      }
    }
    await expect(republishAccountsRoster(poisoned, config, fanout)).resolves.toBeUndefined()
  })
})

describe("credentials plane", () => {
  it("reconciles ferry sources, probes on apply, and rides the harnesses trigger", async () => {
    const fanout = await run(makeEventFanout)
    const { services } = await makeServices("server-x")
    const contents = new Map<string, string | undefined>([
      ["pi-auth", '{"openai":{"key":"sk-1","type":"api_key"}}'],
      ["mystery-source", '{"whatever":true}']
    ])
    const makeSource = (id: string) => ({
      id,
      tombstoneOnAbsence: false,
      read: () => Promise.resolve(contents.get(id)),
      apply: (content: string) => {
        contents.set(id, content)
        return Promise.resolve()
      }
    })
    const refreshed: Array<string | undefined> = []
    const ferrySources = [makeSource("pi-auth"), makeSource("mystery-source")]
    const withFerry: CodevisorServerServices = {
      ...services,
      credentialFerry: ferrySources,
      auth: fakeHarnessAuth({
        sharedOpenCodeProfiles: async () => [makeSource("opencode-profile:work")],
        refresh: (harnessId?: string) => {
          refreshed.push(harnessId)
          return Promise.resolve()
        }
      })
    }

    await run(
      withFerry.db.mergeSyncEntries("harness-credentials", [
        {
          key: "profiles:opencode",
          value: "profiles",
          timestamp: { wallMs: 9, counter: 0, deviceId: "elsewhere" }
        },
        {
          key: "opencode-profile:work",
          value: "key",
          timestamp: { wallMs: 9, counter: 1, deviceId: "elsewhere" }
        },
        {
          key: "pi-auth",
          value: '{"openai":{"key":"fleet","type":"api_key"}}',
          timestamp: { wallMs: 10, counter: 0, deviceId: "elsewhere" }
        },
        {
          key: "mystery-source",
          value: '{"whatever":false}',
          timestamp: { wallMs: 11, counter: 0, deviceId: "elsewhere" }
        }
      ])
    )
    const result = await reconcileForNamespace(withFerry, config, "credentials")
    expect(result).toBeDefined()
    const status = decode(Schema.Struct({ applied: Schema.Array(Schema.String) }))(result?.status)
    expect(status.applied.toSorted()).toEqual([
      "mystery-source",
      "opencode-profile:work",
      "pi-auth"
    ])
    expect(refreshed.toSorted((a, b) => (a ?? "").localeCompare(b ?? ""))).toEqual([
      "opencode",
      "pi"
    ])
    expect(contents.get("pi-auth")).toContain("fleet")

    const withFerryNoAuth: CodevisorServerServices = { ...services, credentialFerry: ferrySources }
    contents.set("pi-auth", '{"openai":{"key":"sk-2","type":"api_key"}}')
    await runBackgroundSyncReconcile(withFerryNoAuth, config, fanout, "harnesses")
    const entries = await run(withFerry.db.getSyncEntries("harness-credentials"))
    expect(entries.find((entry) => entry.key === "pi-auth")?.value).toContain("sk-2")
  })
})
