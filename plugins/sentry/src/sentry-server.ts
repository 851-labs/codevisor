import {
  accountCheckRequest,
  accountRemoveRequest,
  type Clock,
  errorResult,
  eventsExtension,
  eventsPollRequest,
  eventsStreamRequest,
  eventTypeNamed,
  forbiddenError,
  registerEventTypes,
  registerResources,
  registerSkills,
  skillCatalog,
  skillsExtension,
  systemClock,
  unsupportedDeliveryError,
  webhookRequest,
  webhooksExtension
} from "@codevisor/plugin-kit"
import { ProtocolError, Server } from "@modelcontextprotocol/server"

import { missingSentryAccount, rejectedSentrySignIn, sentryAccount } from "./sentry-account.js"
import { type Fetch, SentryApiError, sentryCloudHosts, type SentryHosts } from "./sentry-api.js"
import { checkSentryAccount } from "./sentry-check.js"
import { sentryEventTypes, sentryIngress } from "./sentry-event-catalog.js"
import { createSentryFeeds, type SentryFeeds } from "./sentry-feeds.js"
import { callSentryTool } from "./sentry-mcp.js"
import { sentrySkill } from "./sentry-skill.js"
import { isSentryTool, sentryTools } from "./sentry-tool-catalog.js"

export interface SentryServerOptions {
  fetch?: Fetch
  clock?: Clock
  hosts?: SentryHosts
}

export const sentryCapabilities = {
  tools: {},
  resources: {},
  extensions: {
    [eventsExtension]: { listChanged: false },
    [skillsExtension]: {},
    [webhooksExtension]: { ingress: [sentryIngress] }
  }
}

export const createSentryServer = (options: SentryServerOptions = {}): Server => {
  const fetcher = options.fetch ?? fetch
  const hosts = options.hosts ?? sentryCloudHosts
  const server = new Server(
    { name: "sentry", version: "1.0.0" },
    { capabilities: sentryCapabilities }
  )

  const feeds = createSentryFeeds({ fetch: fetcher, hosts, clock: options.clock ?? systemClock })
  registerTools(server, fetcher, hosts)
  registerEvents(server, feeds)
  registerAccountHooks(server, fetcher, hosts, feeds)
  registerResources(server, skills.resources)
  registerSkills(server, skills)
  return server
}

const registerTools = (server: Server, fetcher: Fetch, hosts: SentryHosts): void => {
  server.setRequestHandler("tools/list", () => ({ tools: [...sentryTools] }))
  server.setRequestHandler("tools/call", (request, ctx) => {
    const account = sentryAccount(ctx.mcpReq._meta)
    if (account === undefined) return errorResult(missingSentryAccount)
    if (!isSentryTool(request.params.name))
      return errorResult(`Unknown tool: ${request.params.name}`)

    return callSentryTool(
      fetcher,
      hosts.mcpUrl,
      account.accessToken,
      request.params.name,
      request.params.arguments ?? {}
    )
  })
}

const registerEvents = (server: Server, feeds: SentryFeeds): void => {
  registerEventTypes(server, sentryEventTypes)
  server.setRequestHandler(eventsPollRequest.method, eventsPollRequest, (params) => {
    eventTypeNamed(sentryEventTypes, params.name)
    throw unsupportedDeliveryError("poll")
  })
  server.setRequestHandler(eventsStreamRequest.method, eventsStreamRequest, (params, ctx) => {
    eventTypeNamed(sentryEventTypes, params.name)
    const account = requireAccount(ctx.mcpReq._meta)

    return feeds.open(params, account, ctx).catch(rethrowAsProtocolError)
  })
}

const registerAccountHooks = (
  server: Server,
  fetcher: Fetch,
  hosts: SentryHosts,
  feeds: SentryFeeds
): void => {
  server.setRequestHandler(webhookRequest.method, webhookRequest, (params, ctx) =>
    feeds.receive(params, requireAccount(ctx.mcpReq._meta))
  )
  server.setRequestHandler(accountCheckRequest.method, accountCheckRequest, (_params, ctx) =>
    checkSentryAccount(fetcher, hosts, ctx.mcpReq._meta)
  )
  server.setRequestHandler(accountRemoveRequest.method, accountRemoveRequest, () => ({}))
}

const requireAccount = (meta: Record<string, unknown> | undefined) => {
  const account = sentryAccount(meta)
  if (account === undefined) throw forbiddenError(missingSentryAccount)

  return account
}

const rethrowAsProtocolError = (error: unknown): never => {
  if (!(error instanceof SentryApiError)) throw error
  if (error.status === unauthorized) throw forbiddenError(rejectedSentrySignIn)

  throw new ProtocolError(upstreamErrorCode, "UpstreamError", {
    status: error.status,
    reason: error.message
  })
}

const unauthorized = 401
const upstreamErrorCode = -32603

const skills = skillCatalog([sentrySkill])
