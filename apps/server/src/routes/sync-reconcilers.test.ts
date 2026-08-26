import { describe, expect, it } from "vitest"
import { makeEventFanout, type CodevisorServerConfig } from "../server-context.js"
import { jsonRequest, makeServices, run, startWithApp } from "../test-support.js"
import {
  configMutationNamespace,
  refreshMcpReadiness,
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
    const server = await startWithApp(services)

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
    for (let attempt = 0; attempt < 100; attempt += 1) {
      const entries = await run(services.db.getSyncEntries("mcps"))
      if (entries.length > 0) break
      await new Promise((resolve) => setTimeout(resolve, 20))
    }
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
