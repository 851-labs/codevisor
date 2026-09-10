import { endpoints } from "@codevisor/api"
import { describe, expect, it, vi, afterEach } from "vitest"
import { CODEVISOR_API_TOOLS } from "./codevisor-api-tools.js"
import { makeCodevisorProvider } from "./codevisor-provider.js"

describe("Codevisor native action parity", () => {
  afterEach(() => vi.unstubAllGlobals())

  it("exposes the pane, plugin and prompt queue HTTP actions used by native clients", () => {
    const equivalents = new Set([
      // Close has the exact same final-pane behavior as DELETE.
      "DELETE /v1/workspaces/:workspaceId/panes/:paneId",
      // Plugin tools are exposed dynamically by the gateway.
      "POST /v1/plugins/:pluginId/tools/:toolName",
      // Artwork transport is not an agent action.
      "GET /v1/plugins/:pluginId/icon",
      "GET /v1/plugins/:pluginId/panes/:paneType/icon"
    ])
    const covered = new Set(CODEVISOR_API_TOOLS.map((tool) => `${tool.method} ${tool.path}`))
    const actions = endpoints.filter(
      (endpoint) =>
        endpoint.includes("/v1/plugins") ||
        endpoint.includes("/v1/workspace") ||
        endpoint.includes("/queue")
    )
    expect(
      actions.filter((endpoint) => !equivalents.has(endpoint) && !covered.has(endpoint))
    ).toEqual([])
  })

  it("preserves nested navigation and promotion bodies, machine scope, and queue ordering", async () => {
    const requests: Array<{ path: string; method: string; body: unknown }> = []
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: URL, init: RequestInit) => {
        requests.push({
          path: url.pathname,
          method: init.method!,
          body: JSON.parse(init.body as string)
        })
        return new Response("{}", { headers: { "content-type": "application/json" } })
      })
    )
    const provider = makeCodevisorProvider(
      () => "http://localhost:5000",
      async () => "token"
    )
    const context = { sessionId: "caller", projectId: "project" }
    await provider.invoke(context, "clients.navigate", {
      clientId: "window/id",
      workspaceId: "w",
      destination: { kind: "pane", id: "p" }
    })
    await provider.invoke(context, "workspaces.pane_promote_chat", {
      workspaceId: "w",
      paneId: "p",
      session: { projectId: "project", harnessId: "codex" }
    })
    await provider.invoke(context, "mcps.machine_set_enabled", {
      mcpId: "codevisor",
      enabled: false
    })
    await provider.invoke(context, "sessions.queue_reorder", { queueItemIds: ["second", "first"] })
    expect(requests).toEqual([
      {
        path: "/v1/clients/window%2Fid/navigate",
        method: "POST",
        body: { workspaceId: "w", destination: { kind: "pane", id: "p" } }
      },
      {
        path: "/v1/workspaces/w/panes/p/promote-chat",
        method: "POST",
        body: { session: { projectId: "project", harnessId: "codex" } }
      },
      { path: "/v1/mcps/codevisor/machine-state", method: "PUT", body: { enabled: false } },
      {
        path: "/v1/sessions/caller/queue",
        method: "PATCH",
        body: { queueItemIds: ["second", "first"] }
      }
    ])
  })
})
