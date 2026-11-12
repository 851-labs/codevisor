import {
  accountCheckRequest,
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
import { Server } from "@modelcontextprotocol/server"

import { missingSlackAccount, slackAccount } from "./slack-account.js"
import { type Fetch, slackApi } from "./slack-api.js"
import { checkSlackAccount } from "./slack-check.js"
import { slackDirectory } from "./slack-directory.js"
import { slackEventTypes, slackIngress } from "./slack-event-catalog.js"
import { localSlackFiles, type SlackFiles } from "./slack-files.js"
import { createSlackPush, type SlackPush } from "./slack-push.js"
import { slackSkill } from "./slack-skill.js"
import { slackTools } from "./slack-tool-catalog.js"
import { runSlackTool } from "./slack-tools.js"

export interface SlackServerOptions {
  fetch?: Fetch
  clock?: Clock
  files?: SlackFiles
}

export const slackCapabilities = {
  tools: {},
  resources: {},
  extensions: {
    [eventsExtension]: { listChanged: false },
    [skillsExtension]: {},
    [webhooksExtension]: { ingress: [slackIngress] }
  }
}

export const createSlackServer = (options: SlackServerOptions = {}): Server => {
  const fetcher = options.fetch ?? fetch
  const server = new Server(
    { name: "slack", version: "1.0.0" },
    { capabilities: slackCapabilities }
  )

  const push = createSlackPush(fetcher, options.clock ?? systemClock)
  registerTools(server, fetcher, options.files ?? localSlackFiles())
  registerEvents(server, push)
  registerAccountHooks(server, fetcher, push)
  registerResources(server, skills.resources)
  registerSkills(server, skills)
  return server
}

const registerTools = (server: Server, fetcher: Fetch, files: SlackFiles): void => {
  server.setRequestHandler("tools/list", () => ({ tools: [...slackTools] }))
  server.setRequestHandler("tools/call", (request, ctx) => {
    const account = slackAccount(ctx.mcpReq._meta)
    if (account === undefined) return errorResult(missingSlackAccount)

    const api = slackApi(fetcher, account.userToken)
    return runSlackTool(request.params.name, request.params.arguments ?? {}, {
      api,
      directory: slackDirectory(api),
      files
    })
  })
}

const registerEvents = (server: Server, push: SlackPush): void => {
  registerEventTypes(server, slackEventTypes)
  server.setRequestHandler(eventsPollRequest.method, eventsPollRequest, (params) => {
    eventTypeNamed(slackEventTypes, params.name)
    throw unsupportedDeliveryError("poll")
  })
  server.setRequestHandler(eventsStreamRequest.method, eventsStreamRequest, (params, ctx) => {
    eventTypeNamed(slackEventTypes, params.name)
    return push.open(params, requireAccount(ctx.mcpReq._meta), ctx)
  })
}

const registerAccountHooks = (server: Server, fetcher: Fetch, push: SlackPush): void => {
  server.setRequestHandler(webhookRequest.method, webhookRequest, (params, ctx) =>
    push.receive(params, requireAccount(ctx.mcpReq._meta))
  )
  server.setRequestHandler(accountCheckRequest.method, accountCheckRequest, (_params, ctx) =>
    checkSlackAccount(fetcher, ctx.mcpReq._meta)
  )
}

const requireAccount = (meta: Record<string, unknown> | undefined) => {
  const account = slackAccount(meta)
  if (account === undefined) throw forbiddenError(missingSlackAccount)

  return account
}

const skills = skillCatalog([slackSkill])
