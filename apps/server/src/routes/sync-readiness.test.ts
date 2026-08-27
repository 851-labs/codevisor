import type { Harness } from "@codevisor/api"
import type { HarnessAuthManager } from "@codevisor/harness-manager"
import { describe, expect, it } from "vitest"
import { jsonRequest, makeServices, pluginsStub, startWithApp } from "../test-support.js"

/// Phase 17: the mcp-readiness surface over HTTP — the on-demand publish
/// endpoint plus the reconcile pass keeping the machine's entry fresh.
describe("/v1/sync/mcp-readiness", () => {
  it("publishes this machine's MCP readiness on demand and after mcps reconciles", async () => {
    const { services } = await makeServices("server-readiness")
    const server = await startWithApp(services, undefined, { id: "server-readiness" })

    const published = await jsonRequest(server, "/v1/sync/mcp-readiness/publish", {
      method: "POST"
    })
    expect(published.status).toBe(200)
    expect(published.body).toEqual({ published: true })
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
    await jsonRequest(server, "/v1/sync/mcp-readiness/publish", { method: "POST" })

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
/// desired-vs-reported matrix, published on demand and after harness passes.
describe("/v1/sync/harness-readiness", () => {
  it("publishes this machine's harness readiness on demand", async () => {
    const { services } = await makeServices("server-hr")
    const server = await startWithApp(services, undefined, { id: "server-hr" })

    const published = await jsonRequest(server, "/v1/sync/harness-readiness/publish", {
      method: "POST"
    })
    expect(published.status).toBe(200)
    expect(published.body).toEqual({ published: true })

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
            readiness: { state: "ready" },
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
            readiness: { state: "notInstalled", detail: "CLI not found on PATH" }
          }))
        ]),
      activeAccountContext: () => Promise.resolve(undefined),
      subscribe: () => () => undefined
    } as unknown as HarnessAuthManager
    const server = await startWithApp({ ...services, auth }, undefined, { id: "server-hr2" })

    await jsonRequest(server, "/v1/sync/harness-readiness/publish", { method: "POST" })
    const document = (await jsonRequest(server, "/v1/sync/harness-readiness")).body as {
      entries: Array<{ value: { harnesses: Array<{ id: string; state: string }> } }>
    }
    const rows = document.entries[0]?.value.harnesses ?? []
    expect(rows.some((row) => row.state === "signInRequired")).toBe(true)
    expect(rows.find((row) => row.id === "legacy-shape")?.state).toBe("ready")
    const missing = rows.find((row) => row.id === "missing-cli") as
      | { state: string; reason?: string }
      | undefined
    expect(missing?.state).toBe("notInstalled")
    expect(missing?.reason).toBe("CLI not found on PATH")
  })
})

/// Phase 24: the plugin-readiness surface — third readiness plane.
describe("/v1/sync/plugin-readiness", () => {
  it("publishes this machine's plugin readiness on demand", async () => {
    const { services } = await makeServices("server-plr")
    const server = await startWithApp({ ...services, plugins: pluginsStub([]) }, undefined, {
      id: "server-plr"
    })

    const published = await jsonRequest(server, "/v1/sync/plugin-readiness/publish", {
      method: "POST"
    })
    expect(published.status).toBe(200)
    expect(published.body).toEqual({ published: true })

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
})
