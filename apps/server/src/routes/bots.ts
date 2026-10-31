import type { IncomingMessage, ServerResponse } from "node:http"

import type { Bot, BotMode, UpdateBotRequest } from "@codevisor/api"
import { UpdateBotRequest as UpdateBotRequestSchema } from "@codevisor/api"
import { trashDirectory } from "@codevisor/worktrees"

import {
  appendAndPublish,
  applyWorkspaceArchiveEffects,
  archiveJobs,
  captureWorkspaceRuntime,
  HttpFailure,
  matchRoute,
  readSchema,
  retireWorkspaceRuntime,
  run,
  swallowError,
  worktreeTrashRoot,
  writeJson,
  type CodevisorServerConfig,
  type CodevisorServerServices,
  type EventFanout,
  type RouteState
} from "../server-context.js"
import { createBot } from "./bot-create.js"
import { renameInstructions, switchInstructionsMode } from "./bot-instructions.js"
import { removeBotCheckout, routeBotProjects, tellBot } from "./bot-projects.js"
import { applySessionUpdate } from "./session-workspace.js"

const getBotOrFail = async (services: CodevisorServerServices, id: string): Promise<Bot> => {
  const bot = await run(services.db.getBot(id))
  if (bot === undefined) throw new HttpFailure(404, `Bot not found: ${id}`)
  return bot
}

const conversationModeNotice = (conversational: boolean): string =>
  conversational
    ? "The user turned on conversation mode for this bot. They now see only the messages you " +
      "send with `machines.current.tools.codevisor.messages.send`, not your replies, and " +
      "Codevisor sends you a `<codevisor-event>` when each of your agents finishes. AGENTS.md " +
      "has the updated instructions; read it and the `codevisor-messages` skill before you reply."
    : "The user turned off conversation mode for this bot. They now read your replies directly, " +
      "so answer in your final reply instead of with `messages.send`, and follow up on your " +
      "agents with `agents.status` or `agents.wait` instead of waiting for a " +
      "`<codevisor-event>`. AGENTS.md has the updated instructions."

const requestedMode = (current: Bot, payload: UpdateBotRequest): BotMode | undefined => {
  if (payload.mode !== undefined || payload.conversational === undefined) return payload.mode
  if (payload.conversational) return "conversation"
  return current.mode === "conversation" ? "transcript" : current.mode
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
  const payload = await readSchema(request, UpdateBotRequestSchema)
  const current = await getBotOrFail(services, id)
  const name = payload.name?.trim()
  if (name !== undefined && name.length === 0) throw new HttpFailure(422, "A bot needs a name")
  const bot = await run(
    services.db.updateBot(current.id, {
      name,
      symbolName: payload.symbolName,
      mode: requestedMode(current, payload),
      isArchived: payload.isArchived
    })
  )
  if (bot.isArchived && !current.isArchived) await retireBotRuntime(services, routeState, bot)
  if (name !== undefined && name !== current.name) {
    await applySessionUpdate(services, fanout, bot.sessionId, {
      title: name,
      titleIntent: "rename"
    })
    const project = await run(services.db.updateProject(bot.projectId, { name }))
    await appendAndPublish(services.db, fanout, "project.updated", project.id, project)
    const workspace = await run(services.db.updateWorkspace(bot.workspaceId, { name }))
    await appendAndPublish(services.db, fanout, "workspace.updated", workspace.id, workspace)
    renameInstructions(bot.rootPath, name)
  }
  if (bot.conversational !== current.conversational) {
    switchInstructionsMode(bot.rootPath, bot.conversational)
    await tellBot(
      services,
      fanout,
      routeState,
      config.id,
      bot,
      "bot.conversation_mode_changed",
      conversationModeNotice(bot.conversational)
    ).catch(swallowError)
  }
  await appendAndPublish(services.db, fanout, "bot.updated", bot.id, { id: bot.id })
  writeJson(response, 200, bot)
  return true
}

const retireBotRuntime = async (
  services: CodevisorServerServices,
  routeState: RouteState,
  bot: Bot
): Promise<void> => {
  const workspaces = (await run(services.db.listWorkspaces)).filter(
    (workspace) => workspace.id === bot.workspaceId
  )
  for (const workspace of workspaces) {
    await retireWorkspaceRuntime(
      services,
      await captureWorkspaceRuntime(services, routeState, workspace)
    )
  }
}

const removeBotCheckouts = async (
  services: CodevisorServerServices,
  serverId: string,
  bot: Bot
): Promise<void> => {
  for (const checkout of bot.projects) {
    await removeBotCheckout(services, serverId, bot, checkout).catch(swallowError)
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
  if (bot === undefined) {
    writeJson(response, 204, undefined)
    return true
  }
  for (const child of await run(services.db.listBotWorkspaces(bot.id))) {
    const archived = await run(services.db.updateWorkspace(child.id, { isArchived: true }))
    await applyWorkspaceArchiveEffects(services, fanout, config, routeState, archived, false)
  }
  await retireBotRuntime(services, routeState, bot)
  await removeBotCheckouts(services, config.id, bot)
  await run(services.db.deleteBot(bot.id))
  await run(services.db.deleteProject(bot.projectId))
  await appendAndPublish(services.db, fanout, "project.deleted", bot.projectId, {
    id: bot.projectId
  })
  await appendAndPublish(services.db, fanout, "bot.updated", bot.id, { id: bot.id })
  const trashed = await trashDirectory(bot.rootPath, {
    trashRoot: worktreeTrashRoot(),
    id: `bot-${bot.id}`
  })
  archiveJobs(services).track(trashed.purged)
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
  const botId = matchRoute(url.pathname, "/v1/bots/:id")
  if (botId === undefined) return false
  if (request.method === "PATCH") {
    return updateBot(services, config, fanout, routeState, botId, request, response)
  }
  if (request.method === "DELETE") {
    return deleteBot(services, config, fanout, routeState, botId, response)
  }
  return false
}
