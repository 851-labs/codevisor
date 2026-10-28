import type { PluginCatalogEntry } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { pluginIconSources } from "./plugin-icon-sources.js"

const entry = (id: string, extra: Partial<PluginCatalogEntry> = {}): PluginCatalogEntry => ({
  id,
  name: id,
  description: "",
  publisher: "acme",
  version: "1",
  source: "popular",
  transport: "http",
  install: { kind: "bundled" },
  capabilities: { tools: [], events: [], skills: [], panes: [], ingress: [] },
  ...extra
})

const catalogOf = (
  listed: ReadonlyArray<PluginCatalogEntry>,
  registry: ReadonlyArray<PluginCatalogEntry> = []
): {
  readonly catalog: Parameters<typeof pluginIconSources>[1]
  readonly resolved: Array<string>
} => {
  const resolved: Array<string> = []
  const catalog = {
    entry: (id: string) => listed.find((candidate) => candidate.id === id),
    resolve: async (id: string) => {
      resolved.push(id)
      return registry.find((candidate) => candidate.id === id)
    }
  }
  return { catalog, resolved }
}

describe("plugin icon sources", () => {
  it("prefers an installed server's own icons, then the catalog's icon and website", async () => {
    const { catalog, resolved } = catalogOf(
      [
        entry("app.linear/linear", {
          url: "https://mcp.linear.app/mcp",
          iconUrl: "https://static.linear.app/icon.png",
          docsUrl: "https://linear.app"
        }),
        entry("dev.codevisor/gmail", { iconUrl: "https://www.gstatic.com/gmail.png" })
      ],
      [entry("io.github.acme/tool")]
    )
    const sources = pluginIconSources(
      async (id) => (id === "server-1" ? { url: "https://mcp.example.com" } : undefined),
      catalog
    )

    expect(await sources("server-1")).toEqual({ url: "https://mcp.example.com" })
    expect(await sources("app.linear/linear")).toEqual({
      url: "https://mcp.linear.app/mcp",
      icons: [{ src: "https://static.linear.app/icon.png" }],
      websiteUrl: "https://linear.app"
    })
    expect(await sources("dev.codevisor/gmail")).toEqual({
      url: "https://www.gstatic.com/gmail.png",
      icons: [{ src: "https://www.gstatic.com/gmail.png" }]
    })
    expect(await sources("io.github.acme/tool")).toEqual({})
    expect(await sources("missing/plugin")).toBeUndefined()
    expect(await sources("4f1c-uuid")).toBeUndefined()
    expect(resolved).toEqual(["io.github.acme/tool", "missing/plugin"])
  })

  it("still finds catalog icons when MCP is unavailable", async () => {
    const { catalog } = catalogOf([
      entry("com.zillow/mcp", { url: "https://mcp.zillow.com/api/v2" })
    ])

    expect(await pluginIconSources(undefined, catalog)("com.zillow/mcp")).toEqual({
      url: "https://mcp.zillow.com/api/v2"
    })
  })
})
