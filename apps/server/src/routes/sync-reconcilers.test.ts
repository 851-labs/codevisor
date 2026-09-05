import { writePluginInstallReceipt } from "@codevisor/plugins"
import { mkdtemp } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { describe, expect, it, vi } from "vitest"
import {
  makeEventFanout,
  type CodevisorServerConfig,
  type CodevisorServerServices
} from "../server-context.js"
import { jsonRequest, makeServices, run, startWithApp } from "../test-support.js"
import {
  configMutationNamespace,
  makeAuthSyncRefreshScheduler,
  refreshHarnessReadiness,
  refreshMcpReadiness,
  refreshPluginReadiness,
  reconcileForNamespace,
  republishAccountsRoster,
  runBackgroundSyncReconcile
} from "./sync-reconcilers.js"

const config = { id: "server-x" } as unknown as CodevisorServerConfig

describe("configMutationNamespace", () => {
  it("maps config mutations to their plane and ignores everything else", () => {
    expect(configMutationNamespace("POST", "/v1/mcps")).toBe("mcps")
    expect(configMutationNamespace("PATCH", "/v1/mcps/abc")).toBe("mcps")
    expect(configMutationNamespace("POST", "/v1/native-mcps/import")).toBe("mcps")
    expect(configMutationNamespace("POST", "/v1/skills")).toBe("skills")
    expect(configMutationNamespace("PATCH", "/v1/harnesses/claude")).toBe("harnesses")
    expect(configMutationNamespace("POST", "/v1/plugins/import-remote")).toBe("plugins")
    expect(configMutationNamespace("DELETE", "/v1/plugins/acme.tunes")).toBe("plugins")

    // Reads never trigger, whatever the path.
    expect(configMutationNamespace("GET", "/v1/mcps")).toBeUndefined()
    expect(configMutationNamespace("HEAD", "/v1/skills")).toBeUndefined()
    expect(configMutationNamespace("OPTIONS", "/v1/plugins")).toBeUndefined()
    expect(configMutationNamespace(undefined, "/v1/mcps")).toBeUndefined()

    // Chatty plugin surfaces are excluded: pane proxies, tokens, tools.
    expect(configMutationNamespace("POST", "/v1/plugins/x/app/api")).toBeUndefined()
    expect(configMutationNamespace("POST", "/v1/plugins/x/panes/p/token")).toBeUndefined()
    expect(configMutationNamespace("POST", "/v1/plugins/x/tools/run")).toBeUndefined()

    // Unrelated mutations never trigger.
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

  it("skips opted-out machines, absent services, and swallows failures", async () => {
    const fanout = await run(makeEventFanout)

    // Participation off: nothing runs.
    const { services: optedOut } = await makeServices("server-bg-off")
    await run(
      optedOut.db.mergeSyncEntries("local.sync", [
        {
          key: "enabled",
          value: false,
          timestamp: { wallMs: 1, counter: 0, deviceId: "z" }
        }
      ])
    )
    await optedOut.mcp?.create({
      authType: "none",
      enabled: false,
      name: "Hidden",
      transport: "http",
      url: "https://hidden.example.com/mcp"
    })
    await runBackgroundSyncReconcile(optedOut, config, fanout, "mcps")
    expect(await run(optedOut.db.getSyncEntries("mcps"))).toEqual([])

    // A plane without its backing services is a silent no-op.
    const { services: bare } = await makeServices("server-bg-bare")
    await runBackgroundSyncReconcile(bare, config, fanout, "skills")
    expect(await run(bare.db.getSyncEntries("skills"))).toEqual([])

    // A reconcile that throws never escapes the hook.
    const { services: broken } = await makeServices("server-bg-broken")
    const throwing = {
      ...broken,
      mcp: {
        ...broken.mcp,
        list: () => Promise.reject(new Error("boom"))
      } as unknown as NonNullable<typeof broken.mcp>
    }
    await expect(
      runBackgroundSyncReconcile(throwing, config, fanout, "mcps")
    ).resolves.toBeUndefined()
  })

  it("fires end to end from a config mutation over HTTP", async () => {
    const { services } = await makeServices("server-bg-http")
    const fanout = await run(makeEventFanout)
    const reconciled = Promise.withResolvers<void>()
    const unsubscribe = fanout.subscribe((event) => {
      if (event.kind === "sync.changed" && event.subjectId === "mcps") reconciled.resolve()
    })
    const server = await startWithApp(services, fanout)

    // A rejected mutation must not reconcile.
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

    // The response-finish hook runs in the background; the replica entry
    // appears without any client calling a reconcile route.
    await reconciled.promise
    unsubscribe()
    const entries = await run(services.db.getSyncEntries("mcps"))
    expect(entries.map((entry) => entry.key)).toEqual(["Imported"])
  })
})

describe("refreshMcpReadiness", () => {
  it("skips machines without MCP services and swallows publish failures", async () => {
    const fanout = await run(makeEventFanout)
    const { services } = await makeServices("server-x")

    // No MCP manager: nothing to derive, nothing published.
    const { mcp: omitted, ...withoutMcp } = services
    void omitted
    await refreshMcpReadiness(withoutMcp, config, fanout)

    // A failing manager never breaks the pass that triggered the refresh.
    const poisoned = {
      ...services,
      mcp: { list: () => Promise.reject(new Error("boom")) }
    } as unknown as typeof services
    await expect(refreshMcpReadiness(poisoned, config, fanout)).resolves.toBeUndefined()
  })
})

describe("auth-derived sync refresh", () => {
  it("derives readiness from stored auth state without starting a passive probe", async () => {
    const fanout = await run(makeEventFanout)
    const { services } = await makeServices("server-auth-readiness")
    const decorateHarnesses = vi.fn(async (harnesses) => harnesses)
    const decorateHarnessesFromStoredState = vi.fn(async (harnesses) => harnesses)
    const withAuth = {
      ...services,
      auth: {
        decorateHarnesses,
        decorateHarnessesFromStoredState
      } as unknown as NonNullable<CodevisorServerServices["auth"]>
    }

    await refreshHarnessReadiness(withAuth, config, fanout)

    expect(decorateHarnessesFromStoredState).toHaveBeenCalledTimes(1)
    expect(decorateHarnesses).not.toHaveBeenCalled()
  })

  it("coalesces event bursts into one active refresh and one trailing refresh", async () => {
    const fanout = await run(makeEventFanout)
    const { services } = await makeServices("server-auth-coalescing")
    let releaseFirstRefresh: () => void = () => undefined
    const firstRefreshGate = new Promise<void>((resolve) => {
      releaseFirstRefresh = resolve
    })
    const firstStarted = Promise.withResolvers<void>()
    const trailingStarted = Promise.withResolvers<void>()
    const decorateHarnessesFromStoredState = vi.fn(async (harnesses) => {
      if (decorateHarnessesFromStoredState.mock.calls.length === 1) {
        firstStarted.resolve()
        await firstRefreshGate
      } else trailingStarted.resolve()
      return harnesses
    })
    const withAuth = {
      ...services,
      auth: {
        decorateHarnesses: vi.fn(async (harnesses) => harnesses),
        decorateHarnessesFromStoredState
      } as unknown as NonNullable<CodevisorServerServices["auth"]>
    }
    const scheduler = makeAuthSyncRefreshScheduler(withAuth, config, fanout)

    for (let index = 0; index < 64; index += 1) scheduler.request()
    await firstStarted.promise
    expect(decorateHarnessesFromStoredState).toHaveBeenCalledTimes(1)

    for (let index = 0; index < 64; index += 1) scheduler.request()
    releaseFirstRefresh()
    await trailingStarted.promise
    expect(decorateHarnessesFromStoredState).toHaveBeenCalledTimes(2)

    scheduler.close()
    scheduler.request()
    expect(decorateHarnessesFromStoredState).toHaveBeenCalledTimes(2)
  })
})

describe("refreshPluginReadiness", () => {
  it("derives every row state and skips machines without a plugins manager", async () => {
    const fanout = await run(makeEventFanout)
    const { services } = await makeServices("server-pr")

    // No plugins manager: nothing derived, nothing published. The shared
    // fixture ships without one, so the services object IS that machine.
    const base = services as unknown as Parameters<typeof refreshPluginReadiness>[0]
    await refreshPluginReadiness(base, config, fanout)
    expect(await run(services.db.getSyncEntries("plugin-readiness"))).toEqual([])

    // A managed install with provenance, one disabled sibling, and a
    // linked dev plugin that never syncs.
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
    const manager = {
      list: async () => ({
        plugins: [
          { enabled: true, id: "owner.example", path: managedPath, source: "managed" },
          { enabled: false, id: "owner.paused", path: managedPath, source: "managed" },
          { enabled: true, id: "dev-linked", path: "/tmp/nowhere", source: "linked" }
        ]
      })
    } as unknown as NonNullable<Parameters<typeof refreshPluginReadiness>[0]["plugins"]>

    // Fleet-desired plugins this machine lacks: one plain, one blocked by
    // the pass, one tombstoned (skipped).
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
    await refreshPluginReadiness({ ...base, plugins: manager }, config, fanout, [
      { id: "fleet.ffmpeg", reason: "needs ffmpeg" }
    ])
    const entries = await run(services.db.getSyncEntries("plugin-readiness"))
    const value = entries[0]?.value as {
      plugins: Array<{ id: string; state: string; reason?: string }>
    }
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

    // A failing manager never breaks the pass that triggered the refresh.
    const poisoned = {
      ...base,
      plugins: { list: () => Promise.reject(new Error("boom")) }
    } as unknown as typeof base
    await expect(refreshPluginReadiness(poisoned, config, fanout)).resolves.toBeUndefined()
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
    const value = entries[0]?.value as { accounts: Array<{ authState: string }> }
    expect(value.accounts[0]?.authState).toBe("authenticated")

    // Unchanged state republishes nothing; a failure never throws.
    await republishAccountsRoster(services, config, fanout)
    expect(await run(services.db.getSyncEntries("harness-accounts"))).toHaveLength(1)
    const poisoned = {
      ...services,
      db: {
        ...services.db,
        getSyncEntries: () => {
          throw new Error("boom")
        }
      }
    } as unknown as typeof services
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
    const withFerry = {
      ...services,
      credentialFerry: ferrySources,
      auth: {
        refresh: (harnessId?: string) => {
          refreshed.push(harnessId)
          return Promise.resolve()
        }
      }
    } as unknown as typeof services

    // Seed a fleet value so the pass APPLIES (covering the probe hook);
    // the unmapped source applies too but probes nothing.
    await run(
      withFerry.db.mergeSyncEntries("harness-credentials", [
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
    expect((result?.status as { applied: string[] }).applied.toSorted()).toEqual([
      "mystery-source",
      "pi-auth"
    ])
    expect(refreshed).toEqual(["pi"])
    expect(contents.get("pi-auth")).toContain("fleet")

    // The harnesses trigger re-runs the ferry: a local edit publishes into
    // the replica without any credentials-specific mutation hook. (No auth
    // service here — the real harnesses pass runs, and the probe hook's
    // optional chain takes its absent side.)
    const withFerryNoAuth = {
      ...services,
      credentialFerry: ferrySources
    } as unknown as typeof services
    contents.set("pi-auth", '{"openai":{"key":"sk-2","type":"api_key"}}')
    await runBackgroundSyncReconcile(withFerryNoAuth, config, fanout, "harnesses")
    const entries = await run(withFerry.db.getSyncEntries("harness-credentials"))
    expect(entries.find((entry) => entry.key === "pi-auth")?.value).toContain("sk-2")
  })
})
