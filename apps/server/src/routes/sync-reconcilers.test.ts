import { decode } from "@codevisor/api"
import type { HarnessAuthManager } from "@codevisor/harness-manager"
import { Schema } from "effect"
import { describe, expect, it, vi } from "vitest"

import { defaultServerConfig } from "../server-config.js"
import {
  makeEventFanout,
  type CodevisorServerConfig,
  type CodevisorServerServices
} from "../server-context.js"
import { jsonRequest, makeServices, run, startWithApp } from "../test-support.js"
import { fakeHarnessAuth } from "./harness-auth-test-support.js"
import { field } from "./response-test-support.js"
import {
  makeAuthSyncRefreshScheduler,
  refreshHarnessReadiness,
  refreshMcpReadiness,
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

    expect(configMutationNamespace("GET", "/v1/mcps")).toBeUndefined()
    expect(configMutationNamespace("HEAD", "/v1/skills")).toBeUndefined()
    expect(configMutationNamespace(undefined, "/v1/mcps")).toBeUndefined()

    expect(configMutationNamespace("POST", "/v1/sessions")).toBeUndefined()
  })
})

describe("runBackgroundSyncReconcile", () => {
  it("ignores a legacy opt-out and swallows failures", async () => {
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

    const { services: broken } = await makeServices("server-bg-broken")
    const throwing: CodevisorServerServices = {
      ...broken,
      mcp: { ...broken.mcp, list: () => Promise.reject(new Error("boom")) }
    }
    await expect(
      runBackgroundSyncReconcile(throwing, config, fanout, "mcps")
    ).resolves.toBeUndefined()
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
  it("swallows publish failures", async () => {
    const fanout = await run(makeEventFanout)
    const { services } = await makeServices("server-x")

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
