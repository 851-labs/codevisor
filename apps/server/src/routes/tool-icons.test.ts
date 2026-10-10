import { describe, expect, it } from "vitest"

import type { ToolIconStore } from "../infra/tool-icons.js"
import { makeServices, runningServers, start, startWithApp } from "../test-support.js"

describe("tool icon routes", () => {
  it("serves site and MCP artwork for the requested appearance, and 404s when there is none", async () => {
    const asked: Array<unknown> = []
    const icon = {
      contentType: "image/png" as const,
      data: new Uint8Array([0x89, 0x50, 0x4e, 0x47])
    }
    const toolIcons: ToolIconStore = {
      site: async (origin, theme) => {
        asked.push({ origin, theme })
        return origin === "https://linear.app" ? icon : undefined
      },
      mcp: async (serverId, host, theme) => {
        asked.push({ serverId, host, theme })
        return serverId === "sentry id" ? icon : undefined
      }
    }
    const { services } = await makeServices("server-a")
    const server = await startWithApp({ ...services, toolIcons })
    runningServers.push(server)

    const site = await fetch(
      `${server.url}/v1/tool-icons/site?origin=${encodeURIComponent("https://linear.app")}&theme=dark`
    )
    expect(site.status).toBe(200)
    expect(site.headers.get("content-type")).toBe("image/png")
    expect(site.headers.get("cache-control")).toBe("private, max-age=86400")
    expect(new Uint8Array(await site.arrayBuffer())).toEqual(icon.data)

    const mcp = await fetch(`${server.url}/v1/tool-icons/mcp/sentry%20id?host=mcp.sentry.dev`)
    expect(mcp.status).toBe(200)
    expect(
      (await fetch(`${server.url}/v1/tool-icons/site?origin=https%3A%2F%2Fbare.example`)).status
    ).toBe(404)
    expect((await fetch(`${server.url}/v1/tool-icons/mcp/stdio`)).status).toBe(404)
    expect((await fetch(`${server.url}/v1/tool-icons/site`)).status).toBe(400)
    expect((await fetch(`${server.url}/v1/tool-icons/other/path`)).status).toBe(404)
    expect((await fetch(`${server.url}/v1/tool-icons/mcp/stdio`, { method: "POST" })).status).toBe(
      404
    )
    expect(asked).toEqual([
      { origin: "https://linear.app", theme: "dark" },
      { serverId: "sentry id", host: "mcp.sentry.dev", theme: "light" },
      { origin: "https://bare.example", theme: "light" },
      { serverId: "stdio", host: undefined, theme: "light" }
    ])
  })

  it("reports the routes unavailable without an icon store", async () => {
    const { server } = await start()
    expect((await fetch(`${server.url}/v1/tool-icons/site?origin=https://a.example`)).status).toBe(
      501
    )
  })
})
