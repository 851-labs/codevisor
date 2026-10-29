import {
  accountRemoveRequest,
  type Clock,
  systemClock,
  eventTypeNamed,
  registerEventTypes,
  eventsExtension,
  forbiddenError,
  PluginProtocolError,
  skillsExtension,
  unsupportedDeliveryError,
  eventsPollRequest,
  eventsStreamRequest,
  registerResources,
  registerSkills,
  skillCatalog,
  errorResult,
  eventErrorCode,
  webhookRequest,
  webhooksExtension
} from "@codevisor/plugin-kit"
import { Server } from "@modelcontextprotocol/sdk/server/index.js"
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js"

import { gmailAccount, missingGmailAccount } from "./gmail-account.js"
import { type Fetch, gmailApi, GmailApiError, rejectedSignIn } from "./gmail-api.js"
import { gmailEventTypes, gmailIngress } from "./gmail-event-catalog.js"
import { pushTopicOf } from "./gmail-push-notification.js"
import { createGmailPush, type GmailPush } from "./gmail-push.js"
import { gmailSkill } from "./gmail-skill.js"
import { gmailTools } from "./gmail-tool-catalog.js"
import { runGmailTool } from "./gmail-tools.js"

export interface GmailServerOptions {
  fetch?: Fetch
  clock?: Clock
}

export const gmailCapabilities = {
  tools: {},
  resources: {},
  extensions: {
    [eventsExtension]: { listChanged: false },
    [skillsExtension]: {},
    [webhooksExtension]: { ingress: [gmailIngress] }
  }
}

export const createGmailServer = (options: GmailServerOptions = {}): Server => {
  const fetcher = options.fetch ?? fetch
  const server = new Server(
    { name: "gmail", version: "1.0.0" },
    { capabilities: gmailCapabilities }
  )

  const push = createGmailPush(fetcher, options.clock ?? systemClock)
  registerTools(server, fetcher)
  registerEvents(server, push)
  registerAccountHooks(server, push)
  registerResources(server, skills.resources)
  registerSkills(server, skills)
  return server
}

const registerTools = (server: Server, fetcher: Fetch): void => {
  server.setRequestHandler(ListToolsRequestSchema, () => ({ tools: [...gmailTools] }))
  server.setRequestHandler(CallToolRequestSchema, (request, extra) => {
    const account = gmailAccount(extra._meta)
    if (account === undefined) return errorResult(missingGmailAccount)

    return runGmailTool(request.params.name, request.params.arguments ?? {}, {
      api: gmailApi(fetcher, account.accessToken),
      identity: account.identity
    })
  })
}

const registerEvents = (server: Server, push: GmailPush): void => {
  registerEventTypes(server, gmailEventTypes)
  server.setRequestHandler(eventsPollRequest, (request) => {
    eventTypeNamed(gmailEventTypes, request.params.name)
    throw unsupportedDeliveryError("poll")
  })
  server.setRequestHandler(eventsStreamRequest, (request, extra) => {
    eventTypeNamed(gmailEventTypes, request.params.name)
    const account = requireAccount(extra._meta)
    const topic = pushTopicOf(extra._meta)
    if (topic === undefined) throw pushUnavailableError()

    return push.open(request.params, account, topic, extra).catch(rethrowAsProtocolError)
  })
}

const registerAccountHooks = (server: Server, push: GmailPush): void => {
  server.setRequestHandler(webhookRequest, (request, extra) =>
    push.receive(request.params, requireAccount(extra._meta))
  )
  server.setRequestHandler(accountRemoveRequest, async (_request, extra) => {
    await push.remove(requireAccount(extra._meta))
    return {}
  })
}

const requireAccount = (meta: Record<string, unknown> | undefined) => {
  const account = gmailAccount(meta)
  if (account === undefined) throw forbiddenError(missingGmailAccount)

  return account
}

const pushUnavailableError = (): PluginProtocolError =>
  new PluginProtocolError(
    eventErrorCode.unsupported,
    "Gmail push isn't set up on this Codevisor Cloud",
    {
      feature: "deliveryMode",
      value: "push"
    }
  )

const rethrowAsProtocolError = (error: unknown): never => {
  if (!(error instanceof GmailApiError)) throw error
  if (rejectedToken(error.status)) throw forbiddenError(rejectedSignIn)

  throw new PluginProtocolError(upstreamErrorCode, "UpstreamError", {
    status: error.status,
    reason: error.message
  })
}

const rejectedToken = (status: number): boolean => status === 401 || status === 403

const upstreamErrorCode = -32603

const skills = skillCatalog([gmailSkill])
