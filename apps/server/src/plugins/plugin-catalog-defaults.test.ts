import { afterEach, describe, expect, it, vi } from "vitest"

import { makePluginCatalog } from "./plugin-catalog.js"

afterEach(() => {
  vi.unstubAllGlobals()
})

describe("plugin catalog defaults", () => {
  it("reads the published catalog with the global fetch from the repository's plugins folder", async () => {
    const requests: Array<string> = []
    vi.stubGlobal("fetch", async (input: URL) => {
      requests.push(String(input))
      return Response.json({
        servers: [
          {
            server: {
              name: "com.example/pub",
              title: "Published",
              remotes: [{ type: "streamable-http", url: "https://example.com/mcp" }]
            }
          }
        ]
      })
    })
    const catalog = makePluginCatalog({ dev: false, execPath: process.execPath })

    await catalog.refreshPublished("https://cloud.test")

    expect(requests).toEqual(["https://cloud.test/v0/servers"])
    expect(catalog.entries().map((entry) => entry.id)).toContain("com.example/pub")
  })
})
