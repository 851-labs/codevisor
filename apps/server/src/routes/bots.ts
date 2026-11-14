import type { IncomingMessage, ServerResponse } from "node:http"

import { BOT_ABOUT_LIMIT, DescribeBotRequest, UpdateBotRequest, type Bot } from "@codevisor/api"

import { archiveAgentsOf } from "../archive-jobs.js"
import {
  appendAndPublish,
  HttpFailure,
  matchRoute,
  readSchema,
  run,
  swallowError,
  writeJson,
  type CodevisorServerConfig,
  type CodevisorServerServices,
  type EventFanout,
  type RouteState
} from "../server-context.js"
import { createBot } from "./bot-create.js"
import { forkBot } from "./bot-fork.js"
import { syncBotInstructions } from "./bot-instructions.js"
import { assertBotMascot } from "./bot-mascots.js"
import { routeBotProjects } from "./bot-projects.js"
import { removeBot, retireBotRuntime } from "./bot-remove.js"
import { botRosterChanged } from "./bot-roster.js"
import { refusePlanConfigForBot } from "./bot-session-modes.js"
import { applySessionConfigPick } from "./session-config.js"
import { applySessionUpdate } from "./session-workspace.js"

const getBotOrFail = async (services: CodevisorServerServices, id: string): Promise<Bot> => {
  const bot = await run(services.db.getBot(id))
  if (bot === undefined) throw new HttpFailure(404, `Bot not found: ${id}`)
  return bot
}

const updateBot = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  routeState: RouteState,
  id: string,
  request: IncomingMessage,
  response: ServerResponse
): Promise<boolean> => {
  const payload = await readSchema(request, UpdateBotRequest)
  const current = await getBotOrFail(services, id)
  const name = payload.name?.trim()
  if (name !== undefined && name.length === 0) throw new HttpFailure(422, "A bot needs a name")
  if (payload.mascot !== undefined) assertBotMascot(payload.mascot)
  await applyConfigSelections(services, config, fanout, current, payload.configSelections ?? {})
  const bot = await run(
    services.db.updateBot(current.id, {
      name,
      symbolName: payload.symbolName,
      mascot: payload.mascot,
      isArchived: payload.isArchived,
      about: payload.about === undefined ? undefined : aboutFrom(payload.about)
    })
  )
  if (bot.isArchived && !current.isArchived) {
    await retireBotRuntime(services, routeState, bot)
    await archiveAgentsOf({ services, fanout, config, turns: routeState }, [bot.sessionId])
  }
  if (name !== undefined && name !== current.name) {
    await applySessionUpdate(services, fanout, bot.sessionId, {
      title: name,
      titleIntent: "rename"
    })
    const project = await run(services.db.updateProject(bot.projectId, { name }))
    await appendAndPublish(services.db, fanout, "project.updated", project.id, project)
    const workspace = await run(services.db.updateWorkspace(bot.workspaceId, { name }))
    await appendAndPublish(services.db, fanout, "workspace.updated", workspace.id, workspace)
  }
  await syncBotInstructions(services, bot).catch(swallowError)
  await appendAndPublish(services.db, fanout, "bot.updated", bot.id, { id: bot.id })
  writeJson(response, 200, bot)
  return true
}

const aboutFrom = (text: string): string => {
  const about = text.trim().replace(/\s+/gu, " ")
  if (about.length > BOT_ABOUT_LIMIT) {
    throw new HttpFailure(422, `Say what the bot does in ${BOT_ABOUT_LIMIT} characters or fewer`)
  }
  return about
}

const describeBot = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  sessionId: string,
  request: IncomingMessage,
  response: ServerResponse
): Promise<boolean> => {
  const payload = await readSchema(request, DescribeBotRequest)
  const current = await run(services.db.findBotOwning({ sessionId }))
  if (current === undefined || current.sessionId.toLowerCase() !== sessionId.toLowerCase()) {
    throw new HttpFailure(403, "Only a bot's own chat can say what it does")
  }
  const bot = await run(services.db.updateBot(current.id, { about: aboutFrom(payload.about) }))
  await appendAndPublish(services.db, fanout, "bot.updated", bot.id, { id: bot.id })
  writeJson(response, 200, bot)
  return true
}

const applyConfigSelections = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  bot: Bot,
  selections: Readonly<Record<string, string>>
): Promise<void> => {
  const picks = Object.entries(selections).map(([configId, value]) => ({ configId, value }))
  for (const pick of picks) await refusePlanConfigForBot(services, bot.sessionId, pick)
  for (const pick of picks) {
    await applySessionConfigPick(services, fanout, config.id, bot.sessionId, pick)
  }
}

const deleteBot = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  routeState: RouteState,
  id: string,
  response: ServerResponse
): Promise<boolean> => {
  const bot = await run(services.db.getBot(id))
  if (bot !== undefined) await removeBot(services, config, fanout, routeState, bot)
  writeJson(response, 204, undefined)
  return true
}

export const routeBots = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  routeState: RouteState,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (await routeBotProjects(services, config, fanout, routeState, request, response, url)) {
    return true
  }
  const handled = await routeBotRecords(
    services,
    config,
    fanout,
    routeState,
    request,
    response,
    url
  )
  if (handled && request.method !== "GET") {
    await botRosterChanged(services, config.id).catch(swallowError)
  }
  return handled
}

const routeBotRecords = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  routeState: RouteState,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  const describedBy = matchRoute(url.pathname, "/v1/sessions/:id/bot/about")
  if (describedBy !== undefined && request.method === "PUT") {
    return describeBot(services, fanout, describedBy, request, response)
  }
  if (url.pathname === "/v1/bots") {
    if (request.method === "GET") {
      writeJson(response, 200, await run(services.db.listBots))
      return true
    }
    if (request.method === "POST") {
      return createBot(services, config, fanout, routeState, request, response)
    }
    return false
  }
  const forkedId = matchRoute(url.pathname, "/v1/bots/:id/fork")
  if (forkedId !== undefined && request.method === "POST") {
    return forkBot(services, config, fanout, routeState, forkedId, request, response)
  }
  const botId = matchRoute(url.pathname, "/v1/bots/:id")
  if (botId === undefined) return false
  if (request.method === "GET") {
    writeJson(response, 200, await getBotOrFail(services, botId))
    return true
  }
  if (request.method === "PATCH") {
    return updateBot(services, config, fanout, routeState, botId, request, response)
  }
  if (request.method === "DELETE") {
    return deleteBot(services, config, fanout, routeState, botId, response)
  }
  return false
}
