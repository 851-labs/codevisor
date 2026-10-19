import type { IncomingMessage, ServerResponse } from "node:http"

import type { Bot } from "@codevisor/api"
import { UpdateBotRequest as UpdateBotRequestSchema } from "@codevisor/api"
import { removeArchivedWorktreeFiles, trashDirectory } from "@codevisor/worktrees"

import {
  appendAndPublish,
  applyWorkspaceArchiveEffects,
  archiveJobs,
  captureWorkspaceRuntime,
  HttpFailure,
  localLocationOrFail,
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
import { renameInstructions } from "./bot-instructions.js"
import { applySessionUpdate } from "./session-workspace.js"

const getBotOrFail = async (services: CodevisorServerServices, id: string): Promise<Bot> => {
  const bot = await run(services.db.getBot(id))
  if (bot === undefined) throw new HttpFailure(404, `Bot not found: ${id}`)
  return bot
}

const updateBot = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  id: string,
  request: IncomingMessage,
  response: ServerResponse
): Promise<boolean> => {
  const payload = await readSchema(request, UpdateBotRequestSchema)
  const current = await getBotOrFail(services, id)
  const name = payload.name?.trim()
  if (name !== undefined && name.length === 0) throw new HttpFailure(422, "A bot needs a name")
  const bot = await run(services.db.updateBot(current.id, { name, symbolName: payload.symbolName }))
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
  await appendAndPublish(services.db, fanout, "bot.updated", bot.id, { id: bot.id })
  writeJson(response, 200, bot)
  return true
}

const removeBotCheckout = async (
  services: CodevisorServerServices,
  serverId: string,
  bot: Bot,
  checkout: Bot["projects"][number]
): Promise<void> => {
  const project = (await run(services.db.listProjects)).find(
    (candidate) => candidate.id === checkout.projectId
  )
  /* v8 ignore next */
  if (project === undefined) return
  const repoDir = localLocationOrFail(serverId, project).folderPath
  const env = await (services.resolveGitEnvironment?.(repoDir) ?? Promise.resolve(process.env))
  const trashed = await removeArchivedWorktreeFiles(repoDir, checkout.path, checkout.branch, {
    trashRoot: worktreeTrashRoot(),
    worktreeId: `bot-${bot.id}-${checkout.folderName}`,
    env
  })
  archiveJobs(services).track(trashed.purged)
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
  const workspaces = (await run(services.db.listWorkspaces)).filter(
    (workspace) => workspace.id === bot.workspaceId
  )
  for (const workspace of workspaces) {
    await retireWorkspaceRuntime(
      services,
      await captureWorkspaceRuntime(services, routeState, workspace)
    )
  }
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
  if (request.method === "PATCH") return updateBot(services, fanout, botId, request, response)
  if (request.method === "DELETE") {
    return deleteBot(services, config, fanout, routeState, botId, response)
  }
  return false
}
