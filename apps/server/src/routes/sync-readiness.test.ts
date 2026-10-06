import type { Harness } from "@codevisor/api"
import type { HarnessAuthManager } from "@codevisor/harness-manager"
import { describe, expect, it } from "vitest"

import {
  makeEventFanout,
  type CodevisorServerConfig,
  type CodevisorServerServices
} from "../server-context.js"
import {
  jsonRequest,
  makeServices,
  pluginsStub,
  pluginSummary,
  run,
  startWithApp
} from "../test-support.js"
import {
  refreshHarnessReadiness,
  refreshMcpReadiness,
  refreshPluginReadiness
} from "./sync-readiness.js"

const machine = (id: string) => ({ id }) as CodevisorServerConfig

/// Phase 17: the mcp-readiness surface over HTTP — the machine's published
/// entry plus the reconcile pass keeping it fresh.
describe("/v1/sync/mcp-readiness", () => {
  it("publishes this machine's MCP readiness and refreshes it after mcps reconciles", async () => {
    const { services } = await makeServices("server-readiness")
    const server = await startWithApp(services, undefined, { id: "server-readiness" })

    await refreshMcpReadiness(services, machine("server-readiness"), await run(makeEventFanout))
    const document = (await jsonRequest(server, "/v1/sync/mcp-readiness")).body as {
      entries: Array<{ key: string; value: { servers: Array<{ name: string; state: string }> } }>
    }
    expect(document.entries).toHaveLength(1)
    expect(document.entries[0]?.key).toBe("server-readiness")
    expect(document.entries[0]?.value.servers.length).toBeGreaterThan(0)

    // An mcps reconcile keeps readiness fresh as a side effect: a new
    // definition shows up in the machine's readiness entry.
    const created = await jsonRequest(server, "/v1/mcps", {
      body: JSON.stringify({
        name: "Fresh",
        transport: "http",
        url: "https://fresh.example/mcp",
        args: [],
        enabled: false,
        authType: "none"
      }),
      method: "POST"
    })
    expect(created.status).toBe(201)
    await jsonRequest(server, "/v1/sync/mcps/reconcile", { method: "POST" })
    const after = (await jsonRequest(server, "/v1/sync/mcp-readiness")).body as {
      entries: Array<{ value: { servers: Array<{ name: string; state: string }> } }>
    }
    expect(after.entries[0]?.value.servers.some((s) => s.name === "Fresh")).toBe(true)
  })

  it("enforces a per-machine disable overlay in the same request cycle", async () => {
    const { services } = await makeServices("server-overlay")
    const server = await startWithApp(services, undefined, { id: "server-overlay" })
    await refreshMcpReadiness(services, machine("server-overlay"), await run(makeEventFanout))

    // Disable a built-in on this machine via the generic overlay surface.
    const put = await jsonRequest(server, "/v1/sync/mcp-overlays", {
      body: JSON.stringify({
        entries: [
          {
            key: "enable|server-overlay|Computer Use",
            value: { enabled: false },
            timestamp: { wallMs: 10, counter: 0, deviceId: "phone" }
          }
        ]
      }),
      method: "PUT"
    })
    expect(put.status).toBe(200)

    // Readiness already reflects the enforced suppression...
    const document = (await jsonRequest(server, "/v1/sync/mcp-readiness")).body as {
      entries: Array<{
        value: { servers: Array<{ name: string; state: string; reason?: string }> }
      }>
    }
    const computer = document.entries[0]?.value.servers.find((s) => s.name === "Computer Use")
    expect(computer).toMatchObject({ state: "disabled", reason: "Disabled on this machine" })
    // ...and sessions on this machine no longer resolve the server.
    const resolved = await services.mcp?.resolved()
    expect(resolved?.some((s) => s.name === "Computer Use")).toBe(false)
  })
})

/// Phase 24: the harness-readiness surface — the reported half of the
/// desired-vs-reported matrix, published on auth changes and after harness
/// passes.
describe("/v1/sync/harness-readiness", () => {
  it("publishes this machine's harness readiness", async () => {
    const { services } = await makeServices("server-hr")
    const server = await startWithApp(services, undefined, { id: "server-hr" })

    await refreshHarnessReadiness(services, machine("server-hr"), await run(makeEventFanout))

    const document = (await jsonRequest(server, "/v1/sync/harness-readiness")).body as {
      entries: Array<{ key: string; value: { harnesses: Array<{ id: string; state: string }> } }>
    }
    expect(document.entries).toHaveLength(1)
    expect(document.entries[0]?.key).toBe("server-hr")
    const rows = document.entries[0]?.value.harnesses ?? []
    expect(rows.length).toBeGreaterThan(0)
    for (const row of rows) {
      expect(["ready", "signInRequired", "notInstalled", "disabled"]).toContain(row.state)
    }
  })

  it("applies global uninstalls and reports their lifecycle state", async () => {
    for (const available of [false, true]) {
      const { services } = await makeServices(`uninstall-${available}`)
      await run(
        services.db.mergeSyncEntries("harnesses", [
          {
            key: "codex",
            value: { enabled: false, installed: false, uninstall: true },
            timestamp: { wallMs: 1, counter: 0, deviceId: "test" }
          }
        ])
      )
      let started = false
      const lifecycle = {
        subscribe: () => () => {},
        onGateReleased: () => () => {},
        decorateHarnesses: async (list: ReadonlyArray<Harness>) => list,
        beginUninstall: async () => {
          started = true
        }
      } as unknown as NonNullable<CodevisorServerServices["lifecycle"]>
      const server = await startWithApp({ ...services, ...(available ? { lifecycle } : {}) })
      const result = await jsonRequest(server, "/v1/sync/harnesses/reconcile", { method: "POST" })
      expect(started).toBe(available)
      expect(result.body).toMatchObject({
        blocked: available ? [] : [{ id: "codex", reason: "Uninstall unavailable on this machine" }]
      })
    }
  })

  it("reports operation progress, errors, and machine overrides", async () => {
    const { services } = await makeServices("operation-report")
    const lifecycle = {
      subscribe: () => () => {},
      onGateReleased: () => () => {},
      decorateHarnesses: async (list: ReadonlyArray<Harness>) =>
        ["installing", "uninstalling", "failed"].flatMap((phase) => [
          {
            ...list[0]!,
            id: phase,
            lifecycle: {
              phase,
              ...(phase === "failed" ? { error: "Package manager unavailable" } : {})
            }
          },
          { ...list[0]!, id: `${phase}-empty`, lifecycle: { phase } }
        ])
    } as unknown as NonNullable<CodevisorServerServices["lifecycle"]>
    const server = await startWithApp({ ...services, lifecycle }, undefined, {
      id: "operation-report"
    })
    await refreshHarnessReadiness(
      { ...services, lifecycle },
      machine("operation-report"),
      await run(makeEventFanout)
    )
    const document = (await jsonRequest(server, "/v1/sync/harness-readiness")).body as {
      entries: Array<{
        value: { harnesses: Array<{ id: string; state: string; reason?: string }> }
      }>
    }
    const rows = document.entries[0]!.value.harnesses
    expect(rows.find((row) => row.id === "uninstalling")?.state).toBe("uninstalling")
    expect(rows.find((row) => row.id === "installing")?.state).toBe("installing")
    expect(rows.find((row) => row.id === "failed")).toMatchObject({
      state: "blocked",
      reason: "Package manager unavailable"
    })
    expect(rows.find((row) => row.id === "failed-empty")).toMatchObject({ state: "blocked" })
  })

  it("reports sign-in-required for installed-but-unauthenticated harnesses", async () => {
    const { services } = await makeServices("server-hr2")
    const auth = {
      // One installed harness awaiting sign-in, and one legacy-shaped row
      // with no desiredEnabled field (the ?? fallback reads enabled).
      decorateHarnesses: (list: ReadonlyArray<Harness>) =>
        Promise.resolve([
          ...list.map((harness) => ({
            ...harness,
            desiredEnabled: true,
            enabled: false,
            readiness: { state: "ready", version: "2.0.24" },
            auth: { state: "unauthenticated" }
          })),
          ...list.map((harness) => {
            const { desiredEnabled: _omitted, ...rest } = harness as Harness & {
              desiredEnabled?: boolean
            }
            return {
              ...rest,
              id: "legacy-shape",
              enabled: true,
              readiness: { state: "ready" },
              auth: { state: "authenticated" }
            }
          }),
          // A desired harness the machine hasn't installed, with the
          // scanner's explanation riding along as the row's reason.
          ...list.map((harness) => ({
            ...harness,
            id: "missing-cli",
            desiredEnabled: true,
            enabled: false,
            // A version left over from a removed CLI never reaches the fleet.
            readiness: { state: "notInstalled", detail: "CLI not found on PATH", version: "1.0.0" }
          })),
          // A sign-in check that failed explains itself on the row.
          ...list.map((harness) => ({
            ...harness,
            id: "auth-error",
            desiredEnabled: true,
            enabled: true,
            readiness: { state: "ready" },
            auth: { state: "error", detail: "Keychain is locked" }
          }))
        ]),
      decorateHarnessesFromStoredState: (list: ReadonlyArray<Harness>) =>
        auth.decorateHarnesses(list),
      activeAccountContext: () => Promise.resolve(undefined),
      subscribe: () => () => undefined
    } as unknown as HarnessAuthManager
    const server = await startWithApp({ ...services, auth }, undefined, { id: "server-hr2" })

    await refreshHarnessReadiness(
      { ...services, auth },
      machine("server-hr2"),
      await run(makeEventFanout)
    )
    const document = (await jsonRequest(server, "/v1/sync/harness-readiness")).body as {
      entries: Array<{ value: { harnesses: Array<{ id: string; state: string }> } }>
    }
    const rows = document.entries[0]?.value.harnesses ?? []
    expect(
      rows
        .filter((row) => row.state === "signInRequired")
        .map((row) => (row as { version?: string }).version)
    ).toContain("2.0.24")
    expect(rows.find((row) => row.id === "legacy-shape")?.state).toBe("ready")
    const missing = rows.find((row) => row.id === "missing-cli") as
      | { state: string; reason?: string }
      | undefined
    expect(missing?.state).toBe("notInstalled")
    expect(missing?.reason).toBe("CLI not found on PATH")
    expect(missing).not.toHaveProperty("version")
    expect(rows.find((row) => row.id === "auth-error")).toMatchObject({
      state: "signInRequired",
      reason: "Keychain is locked"
    })
  })
})

/// Phase 24: the plugin-readiness surface — third readiness plane.
describe("/v1/sync/plugin-readiness", () => {
  it("publishes this machine's plugin readiness", async () => {
    const { services } = await makeServices("server-plr")
    const withPlugins = { ...services, plugins: pluginsStub([]) }
    const server = await startWithApp(withPlugins, undefined, { id: "server-plr" })

    await refreshPluginReadiness(
      withPlugins,
      machine("server-plr"),
      await run(makeEventFanout),
      withPlugins.plugins,
      []
    )

    const document = (await jsonRequest(server, "/v1/sync/plugin-readiness")).body as {
      entries: Array<{ key: string; value: { plugins: Array<{ id: string; state: string }> } }>
    }
    expect(document.entries).toHaveLength(1)
    expect(document.entries[0]?.key).toBe("server-plr")
    // The stub's one plugin is linked — machine-only by definition.
    expect(document.entries[0]?.value.plugins).toEqual([
      { id: "owner.example", state: "machineOnly" }
    ])
  })

  it("reports an enabled plugin whose process died as blocked", async () => {
    const { services } = await makeServices("server-plr-failed")
    const plugins = {
      ...pluginsStub([]),
      list: async () => ({
        plugins: [
          { ...pluginSummary, state: "failed" as const },
          // A disabled plugin in the failed state is not a live failure.
          { ...pluginSummary, id: "owner.off", enabled: false, state: "failed" as const }
        ]
      })
    } as unknown as NonNullable<CodevisorServerServices["plugins"]>
    await refreshPluginReadiness(
      services,
      machine("server-plr-failed"),
      await run(makeEventFanout),
      plugins,
      []
    )
    const entries = await run(services.db.getSyncEntries("plugin-readiness"))
    expect(entries[0]?.value).toEqual({
      plugins: [
        {
          id: "owner.example",
          state: "blocked",
          reason: "The plugin stopped running on this machine. Restart it to try again."
        },
        { id: "owner.off", state: "machineOnly" }
      ]
    })
  })
})
