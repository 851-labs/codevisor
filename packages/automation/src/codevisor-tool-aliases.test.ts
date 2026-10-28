import { afterEach, describe, expect, it, vi } from "vitest"

import { CODEVISOR_TOOL_ALIASES, makeCodevisorProvider } from "./codevisor-provider.js"

afterEach(() => {
  vi.unstubAllGlobals()
})

describe("old Codevisor tool names", () => {
  it("keeps the old mcps.* names working as unlisted aliases of plugins.*", async () => {
    const requests: Array<string> = []
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
        const url = new URL(input instanceof Request ? input.url : input.toString())
        requests.push(`${init?.method ?? "GET"} ${url.pathname}`)
        return Response.json({ ok: true })
      })
    )
    const provider = makeCodevisorProvider(
      () => "http://0.0.0.0:43210",
      async () => "stable-token"
    )
    const context = { sessionId: "session-1", projectId: "project-1" }
    const names = new Set(provider.tools.map((tool) => tool.name))

    await provider.invoke(context, "mcps.list", {})
    await provider.invoke(context, "plugins.list", {})
    await provider.invoke(context, "mcps.delete", { mcpId: "server-1" })
    await provider.invoke(context, "mcps.create", {
      name: "Docs",
      transport: "http",
      url: "https://docs.example.com/mcp"
    })

    expect(requests).toEqual([
      "GET /v1/mcps",
      "GET /v1/mcps",
      "DELETE /v1/mcps/server-1",
      "POST /v1/mcps"
    ])
    for (const [alias, target] of CODEVISOR_TOOL_ALIASES) {
      expect(names.has(alias)).toBe(false)
      expect(names.has(target)).toBe(true)
    }
  })
})
