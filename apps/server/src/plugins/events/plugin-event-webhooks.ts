import { createHash } from "node:crypto"

import type { McpServer, PluginEventType } from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"

import type { InboxWebhookRequest } from "../../infra/cloud-inbox.js"
import { run } from "../../server-context.js"
import { asRecord } from "../../unknown-values.js"
import type { PluginEventConnections } from "./plugin-event-connections.js"
import type { PluginEventIngest } from "./plugin-event-ingest.js"
import type { CloudInboxApi } from "./plugin-event-ingress.js"
import { sourceKeyOf, type EventSource } from "./plugin-event-source-key.js"
import { occurrencesOf } from "./plugin-event-source-modes.js"
import type { EventTimers, WebhookSources } from "./plugin-event-sources.js"
import { newWebhookSecret, verifyWebhook, webhookHeader } from "./standard-webhooks.js"

export interface PluginEventWebhooks extends WebhookSources {
  readonly receive: (request: InboxWebhookRequest) => Promise<void>
}

export interface PluginEventWebhooksDeps {
  readonly db: CodevisorDatabaseService
  readonly connections: PluginEventConnections
  readonly inboxes: CloudInboxApi
  readonly ingest: PluginEventIngest
  readonly timers: EventTimers
  readonly deviceId: () => string | undefined
  readonly pluginKey: (server: McpServer) => string
  readonly now: () => number
}

export const webhookTtlMs = 24 * 60 * 60_000
export const refreshMarginMs = 60 * 60_000
export const minRefreshMs = 60_000

export const makePluginEventWebhooks = (deps: PluginEventWebhooksDeps): PluginEventWebhooks => {
  const routes = new Map<string, WebhookRoute>()
  const seen = new Set<string>()

  const handle = async (route: WebhookRoute, body: unknown): Promise<void> => {
    const record = asRecord(body)
    if (record.type === "gap") return saveCursor(deps.db, route.source, record.cursor)
    if (typeof record.type === "string") return
    await deps.ingest.ingest(route.source, occurrencesOf([record]))
    await saveCursor(deps.db, route.source, record.cursor)
  }

  return {
    run: async (source, type, signal) => {
      const route = await openRoute(deps, source)
      routes.set(route.inboxId, route)
      try {
        await refreshUntilAborted(deps, route, type, signal)
      } finally {
        routes.delete(route.inboxId)
        await closeRoute(deps, route, type)
      }
    },
    receive: async (request) => {
      const route = routes.get(request.inboxId)
      if (route === undefined) return
      const delivery = {
        headers: request.headers,
        body: Buffer.from(request.body, "base64").toString("utf8")
      }
      if (!verifyWebhook(route.secret, delivery, Math.floor(deps.now() / 1000))) return
      const messageId = webhookHeader(request.headers, "webhook-id")!
      if (seen.has(messageId)) return
      seen.add(messageId)
      await handle(route, JSON.parse(delivery.body))
    }
  }
}

interface WebhookRoute {
  readonly source: EventSource
  readonly inboxId: string
  readonly url: string
  readonly secret: string
}

const secretsNamespace = "local.plugin-webhook-secrets"

const openRoute = async (
  deps: PluginEventWebhooksDeps,
  source: EventSource
): Promise<WebhookRoute> => {
  const server = (await deps.connections.servers()).find(
    (candidate) => candidate.id === source.serverId
  )
  const deviceId = deps.deviceId()
  if (server === undefined || deviceId === undefined)
    throw new Error("Webhook delivery needs Codevisor Cloud")
  const inbox = await deps.inboxes.ensure({
    plugin: deps.pluginKey(server),
    accountId: source.accountId ?? "",
    ingress: `events.${deviceId}.${shortHash(sourceKeyOf(source))}`
  })
  await deps.inboxes.subscribe(inbox.id)
  return { source, inboxId: inbox.id, url: inbox.url, secret: await secretFor(deps.db, inbox.id) }
}

const refreshUntilAborted = async (
  deps: PluginEventWebhooksDeps,
  route: WebhookRoute,
  type: PluginEventType,
  signal: AbortSignal
): Promise<void> => {
  const connection = await deps.connections.connection(route.source.serverId)
  while (!signal.aborted) {
    const granted = await connection.request(
      "events/subscribe",
      await subscribeParams(deps.db, route, type),
      requestOptions(route.source, signal)
    )
    await saveCursor(deps.db, route.source, granted.cursor)
    await deps.timers.sleep(refreshDelay(granted.refreshBefore, deps.now()), signal)
  }
}

const closeRoute = async (
  deps: PluginEventWebhooksDeps,
  route: WebhookRoute,
  type: PluginEventType
): Promise<void> => {
  const connection = await deps.connections.connection(route.source.serverId).catch(() => undefined)
  await connection
    ?.request(
      "events/unsubscribe",
      { name: type.name, arguments: route.source.arguments, delivery: { url: route.url } },
      requestOptions(route.source)
    )
    .catch(() => undefined)
  await deps.inboxes.unsubscribe(route.inboxId).catch(() => undefined)
}

const subscribeParams = async (
  db: CodevisorDatabaseService,
  route: WebhookRoute,
  type: PluginEventType
) => ({
  name: type.name,
  arguments: route.source.arguments,
  delivery: { mode: "webhook", url: route.url, secret: route.secret },
  cursor: (await run(db.pluginEventCursor(sourceKeyOf(route.source)))) ?? null,
  ttlMs: webhookTtlMs
})

const requestOptions = (source: EventSource, signal?: AbortSignal) => ({
  ...(signal === undefined ? {} : { signal }),
  ...(source.accountId === undefined ? {} : { accountId: source.accountId })
})

const refreshDelay = (refreshBefore: unknown, now: number): number => {
  if (typeof refreshBefore !== "string") return webhookTtlMs - refreshMarginMs
  return Math.max(minRefreshMs, Date.parse(refreshBefore) - refreshMarginMs - now)
}

const saveCursor = async (
  db: CodevisorDatabaseService,
  source: EventSource,
  cursor: unknown
): Promise<void> => {
  if (typeof cursor !== "string") return
  await run(db.savePluginEventCursor(sourceKeyOf(source), cursor))
}

const secretFor = async (db: CodevisorDatabaseService, inboxId: string): Promise<string> => {
  const stored = (await run(db.getSyncEntries(secretsNamespace))).find(
    (entry) => entry.key === inboxId
  )
  if (typeof stored?.value === "string") return stored.value
  const secret = newWebhookSecret()
  await run(
    db.mergeSyncEntries(secretsNamespace, [
      {
        key: inboxId,
        value: secret,
        timestamp: { wallMs: Date.now(), counter: 0, deviceId: "local" }
      }
    ])
  )
  return secret
}

const shortHash = (value: string): string =>
  createHash("sha256").update(value).digest("hex").slice(0, 16)
