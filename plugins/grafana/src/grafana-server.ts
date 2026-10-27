import {
  type Clock,
  systemClock,
  createEventStreams,
  type EventStreams,
  eventTypeNamed,
  registerEventTypes,
  eventsExtension,
  forbiddenError,
  unsupportedDeliveryError,
  webhooksExtension,
  eventsPollRequest,
  eventsStreamRequest,
  webhookRequest,
  errorResult
} from "@codevisor/plugin-kit"
import { Server } from "@modelcontextprotocol/sdk/server/index.js"
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js"

import { grafanaAccount } from "./grafana-account.js"
import { type Fetch, runGrafanaTool } from "./grafana-api.js"
import { alertsIngress, grafanaEventTypes, grafanaTools } from "./grafana-catalog.js"
import { receiveAlertWebhook } from "./grafana-webhook.js"

export interface GrafanaServerOptions {
  fetch?: Fetch
  clock?: Clock
}

export const grafanaCapabilities = {
  tools: {},
  extensions: {
    [eventsExtension]: { listChanged: false },
    [webhooksExtension]: { ingress: [{ name: alertsIngress, title: "Grafana alert webhook" }] }
  }
}

export const createGrafanaServer = (options: GrafanaServerOptions = {}): Server => {
  const streams = createEventStreams({
    clock: options.clock ?? systemClock,
    heartbeatCursor: () => null
  })
  const server = new Server(
    { name: "grafana", version: "1.0.0" },
    { capabilities: grafanaCapabilities }
  )

  registerTools(server, options.fetch ?? fetch)
  registerEvents(server, streams)
  registerWebhook(server, streams)
  return server
}

const registerTools = (server: Server, fetcher: Fetch): void => {
  server.setRequestHandler(ListToolsRequestSchema, () => ({ tools: [...grafanaTools] }))
  server.setRequestHandler(CallToolRequestSchema, (request, extra) => {
    const account = grafanaAccount(extra._meta)
    if (account === undefined) return errorResult(missingAccount)

    return runGrafanaTool(request.params.name, request.params.arguments ?? {}, account, fetcher)
  })
}

const registerEvents = (server: Server, streams: EventStreams): void => {
  registerEventTypes(server, grafanaEventTypes)
  server.setRequestHandler(eventsPollRequest, (request) => {
    eventTypeNamed(grafanaEventTypes, request.params.name)
    throw unsupportedDeliveryError("poll")
  })
  server.setRequestHandler(eventsStreamRequest, (request, extra) => {
    eventTypeNamed(grafanaEventTypes, request.params.name)
    const account = grafanaAccount(extra._meta)
    if (account === undefined) throw forbiddenError(missingAccount)

    const position = { cursor: null, truncated: false }
    return streams.open(
      { name: request.params.name, accountId: account.id, position, backlog: [] },
      extra
    )
  })
}

const registerWebhook = (server: Server, streams: EventStreams): void => {
  server.setRequestHandler(webhookRequest, (request, extra) => {
    const account = grafanaAccount(extra._meta)
    const outcome = receiveAlertWebhook(request.params, account)
    for (const occurrence of outcome.occurrences) {
      streams.publish(
        occurrence,
        (stream) => stream.accountId === account?.id && stream.name === occurrence.name
      )
    }
    return { accepted: outcome.accepted, status: outcome.status }
  })
}

const missingAccount = "A Grafana account with a url and token is required."
