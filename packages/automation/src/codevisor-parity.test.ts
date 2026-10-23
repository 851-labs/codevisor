import { endpoints } from "@codevisor/api"
import { describe, expect, it, vi, afterEach } from "vitest"

import { CODEVISOR_API_TOOLS } from "./codevisor-api-tools.js"
import { makeCodevisorProvider } from "./codevisor-provider.js"
import { expectString } from "./unknown-values.js"

describe("Codevisor native action parity", () => {
  afterEach(() => vi.unstubAllGlobals())

  it("exposes the pane, plugin, machine and prompt queue HTTP actions used by native clients", () => {
    const equivalents = new Set([
      "GET /v1/clients/:clientId/socket",
      "DELETE /v1/workspaces/:workspaceId/panes/:paneId",
      "POST /v1/plugins/:pluginId/tools/:toolName",
      "GET /v1/plugins/:pluginId/icon",
      "GET /v1/plugins/:pluginId/panes/:paneType/icon"
    ])
    const covered = new Set(CODEVISOR_API_TOOLS.map((tool) => `${tool.method} ${tool.path}`))
    const actions = endpoints.filter(
      (endpoint) =>
        endpoint.includes("/v1/clients") ||
        endpoint.startsWith("POST /v1/machines") ||
        endpoint.startsWith("DELETE /v1/machines") ||
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
          body: JSON.parse(expectString(init.body, "request body"))
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
    await provider.invoke(context, "agents.debug.queue_reorder", {
      agentId: "caller",
      queueItemIds: ["second", "first"]
    })
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
  it("keeps UI command discriminants and nested layout inputs intact", async () => {
    const bodies: unknown[] = []
    vi.stubGlobal(
      "fetch",
      vi.fn(async (_url: URL, init: RequestInit) => {
        bodies.push(JSON.parse(expectString(init.body, "request body")))
        return new Response("{}", { headers: { "content-type": "application/json" } })
      })
    )
    const provider = makeCodevisorProvider(
      () => "http://fixture",
      async () => "token"
    )
    const context = { sessionId: "caller", projectId: "project" }
    const page = { page: "settings", section: "mcps" }
    const layout = {
      workspaceId: "workspace",
      action: {
        kind: "resize",
        tabId: "tab",
        branchPath: [1],
        fractions: [0.4, 0.6],
        expectedChildren: [["left"], ["right"]]
      }
    }
    const window = { action: "frame", x: 30, y: 40, width: 1200, height: 800 }
    await provider.invoke(context, "clients.open_page", { clientId: "client", body: page })
    await provider.invoke(context, "clients.layout", { clientId: "client", ...layout })
    await provider.invoke(context, "clients.window", { clientId: "client", body: window })
    const backgroundTab = { workspaceId: "workspace", action: { kind: "new_tab" }, focus: false }
    const selectedTab = { ...backgroundTab, focus: true }
    await provider.invoke(context, "clients.layout", { clientId: "client", ...backgroundTab })
    await provider.invoke(context, "clients.layout", { clientId: "client", ...selectedTab })
    expect(bodies).toEqual([page, layout, window, backgroundTab, selectedTab])

    const tool = provider.tools.find((candidate) => candidate.name === "clients.layout")!
    expect(tool.inputSchema.required).not.toContain("focus")
    expect(tool.inputSchema.properties?.focus).toMatchObject({
      description: expect.stringContaining("Defaults to false")
    })
  })
})
