import type { Bot } from "@codevisor/api"
import { trashDirectory } from "@codevisor/worktrees"

import {
  appendAndPublish,
  archiveJobs,
  captureWorkspaceRuntime,
  retireWorkspaceRuntime,
  run,
  swallowError,
  worktreeTrashRoot,
  type CodevisorServerConfig,
  type CodevisorServerServices,
  type EventFanout,
  type RouteState
} from "../server-context.js"
import { removeBotCheckout } from "./bot-projects.js"

export const removeBot = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  routeState: RouteState,
  bot: Bot
): Promise<void> => {
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
}

export const retireBotRuntime = async (
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
