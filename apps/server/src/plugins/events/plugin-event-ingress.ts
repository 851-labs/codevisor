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
  readonly subscribe: (inboxId: string) => Promise<void>
  readonly unsubscribe: (inboxId: string) => Promise<void>
}

export interface InboxTarget {
  readonly plugin: string
  readonly accountId: string
  readonly ingress: string
}

export interface PluginEventIngress {
  readonly refresh: (sources: ReadonlyArray<EventSource>) => Promise<void>
  readonly urls: (serverId: string, accountId: string) => Promise<ReadonlyArray<IngressUrl>>
  readonly deliver: (request: InboxWebhookRequest) => Promise<void>
}

export interface PluginEventIngressDeps {
  readonly connections: PluginEventConnections
  readonly inboxes: CloudInboxApi
  readonly pluginKey: (server: McpServer) => string
}

export const makePluginEventIngress = (deps: PluginEventIngressDeps): PluginEventIngress => {
  const routes = new Map<string, IngressRoute>()
  const subscribed = new Set<string>()

  const provision = async (
    server: McpServer,
    accountId: string
  ): Promise<ReadonlyArray<ProvisionedInbox>> => {
    const provisioned: Array<ProvisionedInbox> = []
    for (const ingress of server.capabilities?.ingress ?? []) {
      const target = { plugin: deps.pluginKey(server), accountId, ingress: ingress.name }
      const inbox = await deps.inboxes.ensure(target)
      routes.set(inbox.id, { serverId: server.id, accountId, ingress: ingress.name })
      provisioned.push({ inboxId: inbox.id, url: ingressUrl(ingress, inbox.url) })
    }
    return provisioned
  }

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
      const server = (await deps.connections.servers()).find(
        (candidate) => candidate.id === serverId
      )
      if (server === undefined) return []
      return (await provision(server, accountId)).map((inbox) => inbox.url)
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
  readonly url: IngressUrl
}

const ingressUrl = (ingress: PluginIngress, url: string): IngressUrl => ({
  name: ingress.name,
  ...(ingress.title === undefined ? {} : { title: ingress.title }),
  url
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
