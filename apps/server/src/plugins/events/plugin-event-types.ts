import type { McpServer, PluginEventDelivery, PluginEventType } from "@codevisor/api"

import { offersEvents, type PluginEventConnections } from "./plugin-event-connections.js"

export interface PluginEventTypes {
  readonly list: (query?: string) => Promise<ReadonlyArray<PluginEventType>>
  readonly find: (plugin: string, name: string) => Promise<PluginEventType | undefined>
  readonly forget: (serverId: string) => void
}

export const makePluginEventTypes = (connections: PluginEventConnections): PluginEventTypes => {
  const cache = new Map<string, Promise<ReadonlyArray<PluginEventType>>>()

  const typesOf = (server: McpServer): Promise<ReadonlyArray<PluginEventType>> => {
    const cached = cache.get(server.id)
    if (cached !== undefined) return cached
    const loading = listServerEventTypes(connections, server).catch(() => {
      cache.delete(server.id)
      return []
    })
    cache.set(server.id, loading)
    return loading
  }

  const allTypes = async (): Promise<ReadonlyArray<PluginEventType>> => {
    const servers = (await connections.servers()).filter(offersEvents)
    return (await Promise.all(servers.map(typesOf))).flat()
  }

  return {
    list: async (query) => (await allTypes()).filter((type) => matchesQuery(type, query)),
    find: async (plugin, name) =>
      (await allTypes()).find((type) => namesPlugin(type, plugin) && type.name === name),
    forget: (serverId) => {
      cache.delete(serverId)
    }
  }
}

const maxPages = 20

const listServerEventTypes = async (
  connections: PluginEventConnections,
  server: McpServer
): Promise<ReadonlyArray<PluginEventType>> => {
  const connection = await connections.connection(server.id)
  const types: Array<PluginEventType> = []
  let cursor: string | undefined
  for (let page = 0; page < maxPages; page += 1) {
    const result = await connection.request("events/list", cursorParams(cursor))
    types.push(...eventDescriptors(result.events).map((raw) => eventTypeOf(server, raw)))
    cursor = typeof result.nextCursor === "string" ? result.nextCursor : undefined
    if (cursor === undefined) break
  }
  return types
}

const cursorParams = (cursor: string | undefined): Record<string, unknown> =>
  cursor === undefined ? {} : { cursor }

const eventDescriptors = (value: unknown): ReadonlyArray<Record<string, unknown>> =>
  Array.isArray(value)
    ? value.filter(
        (item): item is Record<string, unknown> =>
          typeof item === "object" && item !== null && typeof item.name === "string"
      )
    : []

const eventTypeOf = (server: McpServer, raw: Record<string, unknown>): PluginEventType => ({
  plugin: server.id,
  pluginName: server.name,
  name: String(raw.name),
  ...(typeof raw.description === "string" ? { description: raw.description } : {}),
  delivery: deliveryModes(raw.delivery),
  ...(raw.inputSchema === undefined ? {} : { inputSchema: raw.inputSchema }),
  ...(raw.payloadSchema === undefined ? {} : { payloadSchema: raw.payloadSchema })
})

const deliveryModes = (value: unknown): ReadonlyArray<PluginEventDelivery> =>
  Array.isArray(value) ? value.filter(isDeliveryMode) : []

const isDeliveryMode = (value: unknown): value is PluginEventDelivery =>
  value === "poll" || value === "push" || value === "webhook"

const namesPlugin = (type: PluginEventType, plugin: string): boolean =>
  type.plugin === plugin || type.pluginName.toLowerCase() === plugin.trim().toLowerCase()

const matchesQuery = (type: PluginEventType, query: string | undefined): boolean => {
  const needle = query?.trim().toLowerCase() ?? ""
  if (needle === "") return true
  return [type.pluginName, type.name, type.description ?? ""].some((text) =>
    text.toLowerCase().includes(needle)
  )
}
