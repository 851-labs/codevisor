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
  listed: ReadonlyArray<PluginCatalogEntry>
): Parameters<typeof pluginIconSources>[1] => ({
  entry: (id: string) => listed.find((candidate) => candidate.id === id)
})

const installedLocally: Parameters<typeof pluginIconSources>[0] = async (id) => {
  if (id === "gmail-server") return { catalogId: "dev.codevisor/gmail" }
  if (id === "unlisted-server") return { catalogId: "dev.codevisor/gone" }
  return {}
}

describe("plugin icon sources", () => {
  it("prefers an installed server's own icons, then the catalog's icon and website", async () => {
    const catalog = catalogOf([
      entry("app.linear/linear", {
        url: "https://mcp.linear.app/mcp",
        iconUrl: "https://static.linear.app/icon.png",
        docsUrl: "https://linear.app"
      }),
      entry("dev.codevisor/gmail", { iconUrl: "https://www.gstatic.com/gmail.png" }),
      entry("dev.codevisor/plain")
    ])
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
    expect(await sources("dev.codevisor/plain")).toEqual({})
    expect(await sources("missing/plugin")).toBeUndefined()
    expect(await sources("4f1c-uuid")).toBeUndefined()
  })

  it("uses the catalog icon for an installed local plugin that has none of its own", async () => {
    const catalog = catalogOf([
      entry("dev.codevisor/gmail", { iconUrl: "https://www.gstatic.com/gmail.png" })
    ])
    const sources = pluginIconSources(installedLocally, catalog)

    expect(await sources("gmail-server")).toEqual({
      url: "https://www.gstatic.com/gmail.png",
      icons: [{ src: "https://www.gstatic.com/gmail.png" }]
    })
    expect(await sources("unlisted-server")).toEqual({ catalogId: "dev.codevisor/gone" })
    expect(await sources("custom-server")).toEqual({})
  })

  it("still finds catalog icons when MCP is unavailable", async () => {
    const catalog = catalogOf([entry("com.zillow/mcp", { url: "https://mcp.zillow.com/api/v2" })])

    expect(await pluginIconSources(undefined, catalog)("com.zillow/mcp")).toEqual({
      url: "https://mcp.zillow.com/api/v2"
    })
  })
})
