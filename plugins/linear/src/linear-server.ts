import {
  accountRemoveRequest,
  type Clock,
  errorResult,
  eventErrorCode,
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

import { linearAccount, missingLinearAccount, rejectedLinearSignIn } from "./linear-account.js"
import { type Fetch, LinearApiError } from "./linear-api.js"
import { linearEventTypes, linearIngress } from "./linear-event-catalog.js"
import { callLinearTool } from "./linear-mcp.js"
import { createLinearPush, type LinearPush } from "./linear-push.js"
import { hasLinearRoute } from "./linear-route.js"
import { linearSkill } from "./linear-skill.js"
import { isLinearTool, linearTools } from "./linear-tool-catalog.js"

export interface LinearServerOptions {
  fetch?: Fetch
  clock?: Clock
}

export const linearCapabilities = {
  tools: {},
  resources: {},
  extensions: {
    [eventsExtension]: { listChanged: false },
    [skillsExtension]: {},
    [webhooksExtension]: { ingress: [linearIngress] }
  }
}

export const createLinearServer = (options: LinearServerOptions = {}): Server => {
  const fetcher = options.fetch ?? fetch
  const server = new Server(
    { name: "linear", version: "1.0.0" },
    { capabilities: linearCapabilities }
  )

  const push = createLinearPush(fetcher, options.clock ?? systemClock)
  registerTools(server, fetcher)
  registerEvents(server, push)
  registerAccountHooks(server, push)
  registerResources(server, skills.resources)
  registerSkills(server, skills)
  return server
}

const registerTools = (server: Server, fetcher: Fetch): void => {
  server.setRequestHandler("tools/list", () => ({ tools: [...linearTools] }))
  server.setRequestHandler("tools/call", (request, ctx) => {
    const account = linearAccount(ctx.mcpReq._meta)
    if (account === undefined) return errorResult(missingLinearAccount)
    if (!isLinearTool(request.params.name))
      return errorResult(`Unknown tool: ${request.params.name}`)

    return callLinearTool(
      fetcher,
      account.accessToken,
      request.params.name,
      request.params.arguments ?? {}
    )
  })
}

const registerEvents = (server: Server, push: LinearPush): void => {
  registerEventTypes(server, linearEventTypes)
  server.setRequestHandler(eventsPollRequest.method, eventsPollRequest, (params) => {
    eventTypeNamed(linearEventTypes, params.name)
    throw unsupportedDeliveryError("poll")
  })
  server.setRequestHandler(eventsStreamRequest.method, eventsStreamRequest, (params, ctx) => {
    eventTypeNamed(linearEventTypes, params.name)
    const account = requireAccount(ctx.mcpReq._meta)
    if (!hasLinearRoute(ctx.mcpReq._meta)) throw pushUnavailableError()

    return push.open(params, account, ctx).catch(rethrowAsProtocolError)
  })
}

const registerAccountHooks = (server: Server, push: LinearPush): void => {
  server.setRequestHandler(webhookRequest.method, webhookRequest, (params, ctx) =>
    push.receive(params, requireAccount(ctx.mcpReq._meta))
  )
  server.setRequestHandler(
    accountRemoveRequest.method,
    accountRemoveRequest,
    async (_params, ctx) => {
      await push.remove(requireAccount(ctx.mcpReq._meta))
      return {}
    }
  )
}

const requireAccount = (meta: Record<string, unknown> | undefined) => {
  const account = linearAccount(meta)
  if (account === undefined) throw forbiddenError(missingLinearAccount)

  return account
}

const pushUnavailableError = (): ProtocolError =>
  new ProtocolError(
    eventErrorCode.unsupported,
    "Linear webhooks aren't set up on this Codevisor Cloud",
    { feature: "deliveryMode", value: "push" }
  )

const rethrowAsProtocolError = (error: unknown): never => {
  if (!(error instanceof LinearApiError)) throw error
  if (error.status === unauthorized) throw forbiddenError(rejectedLinearSignIn)

  throw new ProtocolError(upstreamErrorCode, "UpstreamError", {
    status: error.status,
    reason: error.message
  })
}

const unauthorized = 401
const upstreamErrorCode = -32603

const skills = skillCatalog([linearSkill])
