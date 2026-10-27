import { Hono, type Context } from "hono"
import { z } from "zod"

import type { CloudEnv } from "./env.js"
import bundledCatalog from "./generated/plugin-catalog.json"
import { pluginAgeRatings, type PluginAgeRating } from "./plugin-moderation.js"

export type RegistryServer = z.infer<typeof RegistryServer>

export interface RegistryServerResponse {
  server: RegistryServer
  _meta: Record<string, unknown>
}

export const pluginMetaKey = "dev.codevisor/plugin"
export const officialMetaKey = "io.modelcontextprotocol.registry/official"

export const pluginCatalog = new Hono<{ Bindings: CloudEnv }>()

pluginCatalog.get("/v0/servers", async (c) => {
  const servers = await ratedServers(c.env.DB)
  const matching = servers.filter(searchFilter(c.req.query("search")))
  return catalogJson(c, {
    servers: matching.map(serverResponse),
    metadata: { count: matching.length }
  })
})

pluginCatalog.get("/v0/servers/:name{.+}/versions/latest", async (c) => {
  const name = c.req.param("name")
  const server = (await ratedServers(c.env.DB)).find((candidate) => candidate.name === name)
  if (server === undefined) return c.json({ error: "Server not found" }, 404)

  return catalogJson(c, serverResponse(server))
})

const cacheControl = "public, max-age=300"
const metaRecord = z.record(z.string(), z.unknown())

const RegistryServer = z.looseObject({
  name: z.string().min(1),
  title: z.string().optional(),
  _meta: metaRecord.optional()
})

const BundledCatalog = z.object({
  firstParty: z.array(RegistryServer),
  popular: z.object({ servers: z.array(z.object({ server: RegistryServer })) })
})

const listedServers = (): RegistryServer[] => {
  const catalog = BundledCatalog.parse(bundledCatalog)
  const firstParty = catalog.firstParty.filter((server) => !isDevOnly(server))
  return [...firstParty, ...catalog.popular.servers.map((entry) => entry.server)]
}

const isDevOnly = (server: RegistryServer): boolean => pluginMeta(server).devOnly === true

const pluginMeta = (server: RegistryServer): Record<string, unknown> => {
  const parsed = metaRecord.safeParse(server._meta?.[pluginMetaKey])
  return parsed.success ? parsed.data : {}
}

const catalogServers = listedServers()

const ratedServers = async (db: D1Database): Promise<RegistryServer[]> => {
  const ratings = ageRatingsById(await pluginAgeRatings(db))
  return catalogServers.map((server) => withAgeRating(server, ratings.get(server.name)))
}

const ageRatingsById = (ratings: ReadonlyArray<PluginAgeRating>): Map<string, number> =>
  new Map(ratings.map((rating) => [rating.pluginId, rating.minimumAge]))

const withAgeRating = (server: RegistryServer, ageRating: number | undefined): RegistryServer => {
  if (ageRating === undefined) return server

  const meta = { ...pluginMeta(server), ageRating }
  return { ...server, _meta: { ...server._meta, [pluginMetaKey]: meta } }
}

const searchFilter = (search: string | undefined) => {
  const needle = search?.trim().toLowerCase() ?? ""
  return (server: RegistryServer): boolean => needle === "" || searchText(server).includes(needle)
}

const searchText = (server: RegistryServer): string =>
  `${server.name}\n${server.title ?? ""}`.toLowerCase()

const serverResponse = (server: RegistryServer): RegistryServerResponse => ({
  server,
  _meta: { [officialMetaKey]: { status: "active", isLatest: true } }
})

const catalogJson = (c: Context<{ Bindings: CloudEnv }>, body: object) =>
  c.json(body, 200, { "cache-control": cacheControl })
