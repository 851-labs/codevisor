import {
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
  errorResult
} from "@codevisor/plugin-kit"
import { Server } from "@modelcontextprotocol/sdk/server/index.js"
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js"

import { gmailAccount, missingGmailAccount } from "./gmail-account.js"
import { type Fetch, gmailApi, GmailApiError } from "./gmail-api.js"
import { gmailEventTypes, gmailTools } from "./gmail-catalog.js"
import { pollMessages } from "./gmail-poll.js"
import { gmailRepliesSkill } from "./gmail-skill.js"
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
    [skillsExtension]: {}
  }
}

export const createGmailServer = (options: GmailServerOptions = {}): Server => {
  const fetcher = options.fetch ?? fetch
  const server = new Server(
    { name: "gmail", version: "1.0.0" },
    { capabilities: gmailCapabilities }
  )

  registerTools(server, fetcher)
  registerEvents(server, fetcher, options.clock ?? systemClock)
  registerResources(server, skills.resources)
  registerSkills(server, skills)
  return server
}

const registerTools = (server: Server, fetcher: Fetch): void => {
  server.setRequestHandler(ListToolsRequestSchema, () => ({ tools: [...gmailTools] }))
  server.setRequestHandler(CallToolRequestSchema, (request, extra) => {
    const account = gmailAccount(extra._meta)
    if (account === undefined) return errorResult(missingGmailAccount)

    return runGmailTool(
      request.params.name,
      request.params.arguments ?? {},
      gmailApi(fetcher, account.accessToken)
    )
  })
}

const registerEvents = (server: Server, fetcher: Fetch, clock: Clock): void => {
  registerEventTypes(server, gmailEventTypes)
  server.setRequestHandler(eventsPollRequest, (request, extra) => {
    eventTypeNamed(gmailEventTypes, request.params.name)
    const account = gmailAccount(extra._meta)
    if (account === undefined) throw forbiddenError(missingGmailAccount)

    const api = gmailApi(fetcher, account.accessToken)
    return pollMessages(api, account.identity, request.params, clock.now()).catch(
      rethrowAsProtocolError
    )
  })
  server.setRequestHandler(eventsStreamRequest, (request) => {
    eventTypeNamed(gmailEventTypes, request.params.name)
    throw unsupportedDeliveryError("push")
  })
}

const rethrowAsProtocolError = (error: unknown): never => {
  if (!(error instanceof GmailApiError)) throw error
  if (rejectedToken(error.status)) throw forbiddenError("Gmail rejected the access token.")

  throw new PluginProtocolError(upstreamErrorCode, "UpstreamError", {
    status: error.status,
    reason: error.message
  })
}

const rejectedToken = (status: number): boolean => status === 401 || status === 403

const upstreamErrorCode = -32603

const skills = skillCatalog([gmailRepliesSkill])
