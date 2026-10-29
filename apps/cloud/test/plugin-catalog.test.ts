import { env, SELF } from "cloudflare:test"
import { afterEach, describe, expect, it } from "vitest"
import { z } from "zod"

import { BASE } from "./cloud-test-support.js"
import { readJson } from "./json-test-support.js"

const official = {
  "io.modelcontextprotocol.registry/official": {
    status: "active",
    isLatest: true
  }
}
const ratedIds = ["io.sentry/mcp", "app.linear/linear"]

const ServerBody = z.looseObject({
  name: z.string(),
  _meta: z.record(z.string(), z.unknown()).optional()
})
const ServerResponseBody = z.object({ server: ServerBody, _meta: z.unknown() })
const ServerListBody = z.object({
  servers: z.array(ServerResponseBody),
  metadata: z.object({ count: z.number() })
})

const listServers = async (query = "") =>
  readJson(await SELF.fetch(`${BASE}/v0/servers${query}`), ServerListBody)

const names = (body: z.infer<typeof ServerListBody>): string[] =>
  body.servers.map((entry) => entry.server.name)

const serverNamed = (body: z.infer<typeof ServerListBody>, name: string) => {
  const entry = body.servers.find((candidate) => candidate.server.name === name)
  if (entry === undefined) throw new Error(`missing ${name}`)
  return entry.server
}

const pluginMeta = (server: z.infer<typeof ServerBody>): Record<string, unknown> =>
  z.record(z.string(), z.unknown()).parse(server._meta?.["dev.codevisor/plugin"] ?? {})

const rate = (pluginId: string, minimumAge: number) =>
  env.DB.prepare("INSERT OR REPLACE INTO plugin_age_ratings (plugin_id, minimum_age) VALUES (?, ?)")
    .bind(pluginId, minimumAge)
    .run()

afterEach(async () => {
  for (const pluginId of ratedIds) {
    await env.DB.prepare("DELETE FROM plugin_age_ratings WHERE plugin_id = ?").bind(pluginId).run()
  }
})

describe("plugin catalog", () => {
  it("lists catalog plugins in MCP Registry format without dev-only plugins", async () => {
    const response = await SELF.fetch(`${BASE}/v0/servers`)
    const body = await readJson(response, ServerListBody)

    expect(response.headers.get("cache-control")).toBe("public, max-age=300")
    expect(names(body)).toEqual(expect.arrayContaining(["app.linear/linear", "com.notion/mcp"]))
    expect(names(body)).not.toContain("dev.codevisor/test-events")
    expect(body.metadata.count).toBe(body.servers.length)
    expect(body.servers.map((entry) => entry._meta)).toEqual(body.servers.map(() => official))
  })

  it("filters by name or title, ignoring case", async () => {
    expect(names(await listServers("?search=LINEAR"))).toEqual(["app.linear/linear"])
    expect(names(await listServers("?search=sentry"))).toEqual(["io.sentry/mcp"])
    expect(await listServers("?search=no-such-plugin")).toEqual({
      servers: [],
      metadata: { count: 0 }
    })
  })

  it("merges age ratings into the Codevisor plugin metadata", async () => {
    const sentry = "io.sentry/mcp"
    const unrated = pluginMeta(serverNamed(await listServers(), sentry))
    await rate(sentry, 16)
    await rate("app.linear/linear", 18)

    const body = await listServers()

    expect(unrated).toEqual({ ageRating: 4 })
    expect(pluginMeta(serverNamed(body, sentry))).toEqual({
      ...unrated,
      ageRating: 16
    })
    expect(pluginMeta(serverNamed(body, "app.linear/linear"))).toEqual({
      ageRating: 18
    })
  })

  it("serves the latest version of one server by its encoded name", async () => {
    await rate("app.linear/linear", 18)

    const response = await SELF.fetch(`${BASE}/v0/servers/app.linear%2Flinear/versions/latest`)
    const body = await readJson(response, ServerResponseBody)

    expect(body._meta).toEqual(official)
    expect(body.server).toMatchObject({
      name: "app.linear/linear",
      title: "Linear",
      _meta: { "dev.codevisor/plugin": { ageRating: 18 } }
    })
    expect((await SELF.fetch(`${BASE}/v0/servers/com.notion%2Fmcp/versions/latest`)).status).toBe(
      200
    )
  })

  it("answers older apps with an empty index of the retired plugin registry", async () => {
    const response = await SELF.fetch(`${BASE}/plugins/index.json`)

    expect(response.status).toBe(200)
    expect(await response.json()).toEqual({ generatedAt: null, entries: [], rejected: [] })
  })

  it("does not serve unknown or dev-only servers", async () => {
    for (const name of ["acme%2Fmissing", "dev.codevisor%2Ftest-events"]) {
      const response = await SELF.fetch(`${BASE}/v0/servers/${name}/versions/latest`)
      expect(response.status).toBe(404)
    }
  })
})
