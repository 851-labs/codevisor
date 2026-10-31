import { createHash } from "node:crypto"

import type { McpServer, PluginIngress } from "@codevisor/api"

import type { InboxWebhookRequest } from "../../infra/cloud-inbox.js"
import type { PluginEventConnections } from "./plugin-event-connections.js"
import type { EventSource } from "./plugin-event-source-key.js"

export interface IngressUrl {
  readonly name: string
  readonly title?: string
  readonly url: string
}

export interface CloudInboxApi {
  readonly ensure: (target: InboxTarget) => Promise<{ readonly id: string; readonly url: string }>
  readonly find: (target: InboxTarget) => Promise<string | undefined>
  readonly subscribe: (inboxId: string) => Promise<void>
  readonly unsubscribe: (inboxId: string) => Promise<void>
  readonly route: (inboxId: string, route: string, key: string) => Promise<RouteConfig>
  readonly remove: (inboxId: string) => Promise<void>
}

export type RouteConfig = Readonly<Record<string, string>>

export interface InboxTarget {
  readonly plugin: string
  readonly accountId: string
  readonly ingress: string
}

export interface PluginEventIngress {
  readonly refresh: (sources: ReadonlyArray<EventSource>) => Promise<void>
  readonly urls: (serverId: string, accountId: string) => Promise<ReadonlyArray<IngressUrl>>
  readonly meta: (serverId: string, accountId: string) => Promise<Record<string, unknown>>
  readonly forget: (serverId: string, accountId: string) => Promise<void>
  readonly deliver: (request: InboxWebhookRequest) => Promise<void>
}

export interface PluginEventIngressDeps {
  readonly connections: PluginEventConnections
  readonly inboxes: CloudInboxApi
  readonly pluginKey: (server: McpServer) => string
  readonly identity: (serverId: string, accountId: string) => Promise<string | undefined>
}

export const ingressMetaKey = "dev.codevisor/ingress"

export const makePluginEventIngress = (deps: PluginEventIngressDeps): PluginEventIngress => {
  const routes = new Map<string, IngressRoute>()
  const subscribed = new Set<string>()

  const routeConfig = async (
    server: McpServer,
    accountId: string,
    ingress: PluginIngress,
    inboxId: string
  ): Promise<RouteConfig | undefined> => {
    if (ingress.route === undefined) return undefined

    const identity = await deps.identity(server.id, accountId)
    if (identity === undefined) return undefined

    return deps.inboxes.route(inboxId, ingress.route, routeKey(identity))
  }

  const provision = async (
    server: McpServer,
    accountId: string
  ): Promise<ReadonlyArray<ProvisionedInbox>> => {
    const provisioned: Array<ProvisionedInbox> = []
    for (const ingress of declaredIngress(server)) {
      const inbox = await deps.inboxes.ensure(inboxTarget(deps, server, accountId, ingress))
      routes.set(inbox.id, { serverId: server.id, accountId, ingress: ingress.name })
      const config = await routeConfig(server, accountId, ingress, inbox.id)
      provisioned.push({ inboxId: inbox.id, ingress, url: inbox.url, config })
    }
    return provisioned
  }

  const serverNamed = async (serverId: string): Promise<McpServer | undefined> =>
    (await deps.connections.servers()).find((candidate) => candidate.id === serverId)

  const wantedInboxes = async (
    sources: ReadonlyArray<EventSource>
  ): Promise<ReadonlySet<string>> => {
    const servers = await deps.connections.servers()
    const wanted = new Set<string>()
    for (const target of ingressTargets(servers, sources)) {
      const server = servers.find((candidate) => candidate.id === target.serverId)!
      for (const inbox of await provision(server, target.accountId)) wanted.add(inbox.inboxId)
    }
    return wanted
  }

  return {
    refresh: async (sources) => {
      const wanted = await wantedInboxes(sources)
      for (const inboxId of wanted) {
        if (subscribed.has(inboxId)) continue
        await deps.inboxes.subscribe(inboxId)
        subscribed.add(inboxId)
      }
      for (const inboxId of subscribed) {
        if (wanted.has(inboxId)) continue
        await deps.inboxes.unsubscribe(inboxId)
        subscribed.delete(inboxId)
      }
    },
    urls: async (serverId, accountId) => {
      const server = await serverNamed(serverId)
      if (server === undefined) return []
      return (await provision(server, accountId)).filter(pasted).map(ingressUrl)
    },
    meta: async (serverId, accountId) => {
      const server = await serverNamed(serverId)
      if (server === undefined) return {}
      return {
        [ingressMetaKey]: { ingress: (await provision(server, accountId)).map(ingressEntry) }
      }
    },
    forget: async (serverId, accountId) => {
      const server = await serverNamed(serverId)
      if (server === undefined) return
      for (const ingress of declaredIngress(server)) {
        const inboxId = await deps.inboxes.find(inboxTarget(deps, server, accountId, ingress))
        if (inboxId === undefined) continue

        routes.delete(inboxId)
        subscribed.delete(inboxId)
        await deps.inboxes.remove(inboxId)
      }
    },
    deliver: async (request) => {
      const route = routes.get(request.inboxId)
      if (route === undefined) return
      const connection = await deps.connections.connection(route.serverId)
      await connection.request("codevisor/webhook", webhookParams(route, request), {
        accountId: route.accountId
      })
    }
  }
}

interface IngressRoute {
  readonly serverId: string
  readonly accountId: string
  readonly ingress: string
}

interface IngressTarget {
  readonly serverId: string
  readonly accountId: string
}

const ingressTargets = (
  servers: ReadonlyArray<McpServer>,
  sources: ReadonlyArray<EventSource>
): ReadonlyArray<IngressTarget> => {
  const targets = new Map<string, IngressTarget>()
  for (const source of sources) {
    if (source.accountId === undefined || !hasIngress(servers, source.serverId)) continue
    targets.set(`${source.serverId}\0${source.accountId}`, {
      serverId: source.serverId,
      accountId: source.accountId
    })
  }
  return [...targets.values()]
}

const hasIngress = (servers: ReadonlyArray<McpServer>, serverId: string): boolean =>
  (servers.find((server) => server.id === serverId)?.capabilities?.ingress.length ?? 0) > 0

interface ProvisionedInbox {
  readonly inboxId: string
  readonly ingress: PluginIngress
  readonly url: string
  readonly config: RouteConfig | undefined
}

const declaredIngress = (server: McpServer): ReadonlyArray<PluginIngress> =>
  server.capabilities?.ingress ?? []

const inboxTarget = (
  deps: PluginEventIngressDeps,
  server: McpServer,
  accountId: string,
  ingress: PluginIngress
): InboxTarget => ({ plugin: deps.pluginKey(server), accountId, ingress: ingress.name })

const routeKey = (identity: string): string =>
  createHash("sha256").update(identity.trim().toLowerCase(), "utf8").digest("hex")

const pasted = (inbox: ProvisionedInbox): boolean => inbox.ingress.route === undefined

const ingressUrl = (inbox: ProvisionedInbox): IngressUrl => ({
  name: inbox.ingress.name,
  ...(inbox.ingress.title === undefined ? {} : { title: inbox.ingress.title }),
  url: inbox.url
})

const ingressEntry = (inbox: ProvisionedInbox) => ({
  name: inbox.ingress.name,
  url: inbox.url,
  ...(inbox.config === undefined || inbox.ingress.route === undefined
    ? {}
    : { route: { name: inbox.ingress.route, ...inbox.config } })
})

const webhookParams = (route: IngressRoute, request: InboxWebhookRequest) => ({
  ingress: route.ingress,
  request: {
    method: request.method,
    headers: request.headers,
    body: request.body,
    receivedAt: request.receivedAt
  }
})
