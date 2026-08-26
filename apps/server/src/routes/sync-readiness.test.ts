import { describe, expect, it } from "vitest"
import { jsonRequest, makeServices, startWithApp } from "../test-support.js"

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
