import { readdirSync } from "node:fs"
import type { IncomingMessage, ServerResponse } from "node:http"
import { basename } from "node:path"

import type { Bot } from "@codevisor/api"
import { AddBotProjectRequest } from "@codevisor/api"
import { removeArchivedWorktreeFiles, rollbackFailedWorktree } from "@codevisor/worktrees"

import {
  appendAndPublish,
  archiveJobs,
  getProjectOrFail,
  HttpFailure,
  localLocationOrFail,
  matchRouteParams,
  readSchema,
  run,
  swallowError,
  worktreeTrashRoot,
  writeJson,
  type CodevisorServerConfig,
  type CodevisorServerServices,
  type EventFanout,
  type RouteState
} from "../server-context.js"
import { checkOut, resolveSources } from "./bot-create.js"
import { syncBotRepositories } from "./bot-instructions.js"
import { drainPromptQueue } from "./prompt-queue.js"

type BotCheckout = Bot["projects"][number]

interface BotProjectChange {
  readonly bot: Bot
  readonly notice?: string
}

const changeQueues = new WeakMap<CodevisorServerServices, Map<string, Promise<unknown>>>()

const oneChangeAtATime = <A>(
  services: CodevisorServerServices,
  botId: string,
  operation: () => Promise<A>
): Promise<A> => {
  let queues = changeQueues.get(services)
  if (queues === undefined) {
    queues = new Map()
    changeQueues.set(services, queues)
  }
  const pending = (queues.get(botId) ?? Promise.resolve())
    .catch(() => undefined)
    .then(operation)
    .finally(() => {
      if (queues.get(botId) === pending) queues.delete(botId)
    })
  queues.set(botId, pending)
  return pending
}

const sameId = (left: string, right: string): boolean => left.toLowerCase() === right.toLowerCase()

export const removeBotCheckout = async (
  services: CodevisorServerServices,
  serverId: string,
  bot: Bot,
  checkout: BotCheckout
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

const takenFolders = (bot: Bot): Set<string> => {
  let entries: ReadonlyArray<string> = []
  try {
    entries = readdirSync(bot.rootPath)
  } catch {}
  return new Set([...entries, ...bot.projects.map((checkout) => checkout.folderName)])
}

const addProject = async (
  services: CodevisorServerServices,
  serverId: string,
  current: Bot,
  projectId: string
): Promise<BotProjectChange> => {
  if (current.projects.some((checkout) => sameId(checkout.projectId, projectId))) {
    return { bot: current }
  }
  const [source] = await resolveSources(services, serverId, [projectId])
  const checkout = await checkOut(
    services,
    basename(current.rootPath),
    source!,
    takenFolders(current)
  )
  const bot = await run(
    services.db.addBotProject(current.id, {
      projectId: checkout.source.project.id,
      folderName: checkout.folderName,
      branch: checkout.branch
    })
  ).catch(async (cause: unknown) => {
    await rollbackFailedWorktree(
      checkout.source.repoDir,
      checkout.path,
      checkout.branch,
      checkout.env
    ).catch(swallowError)
    throw cause
  })
  await syncBotRepositories(services, bot)
  return {
    bot,
    notice:
      `The user added the repository ${checkout.source.project.name} to this bot. Its ` +
      `read-only checkout is at \`${checkout.folderName}/\` (projectId ` +
      `\`${checkout.source.project.id}\`), and AGENTS.md lists every repository you have now.`
  }
}

const removeProject = async (
  services: CodevisorServerServices,
  serverId: string,
  current: Bot,
  projectId: string
): Promise<BotProjectChange> => {
  const checkout = current.projects.find((candidate) => sameId(candidate.projectId, projectId))
  if (checkout === undefined) {
    throw new HttpFailure(404, `Project ${projectId} isn't part of the bot ${current.name}`)
  }
  if (current.projects.length === 1) {
    throw new HttpFailure(422, "A bot needs at least one project")
  }
  const project = await getProjectOrFail(services.db, checkout.projectId)
  const bot = await run(services.db.removeBotProject(current.id, checkout.projectId))
  await removeBotCheckout(services, serverId, bot, checkout).catch(swallowError)
  await syncBotRepositories(services, bot)
  return {
    bot,
    notice:
      `The user removed the repository ${project.name} (projectId ` +
      `\`${checkout.projectId}\`) from this bot. Its \`${checkout.folderName}/\` checkout is ` +
      "gone, and AGENTS.md lists every repository you have now."
  }
}

const tellBot = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  routeState: RouteState,
  serverId: string,
  bot: Bot,
  notice: string
): Promise<void> => {
  const event = [`<codevisor-event type="bot.projects_changed">`, notice, "</codevisor-event>"]
  await run(
    services.db.createPromptQueueItem(
      bot.sessionId,
      event.join("\n"),
      [],
      undefined,
      undefined,
      "system"
    )
  )
  await drainPromptQueue(services, fanout, routeState, serverId, bot.sessionId)
}

type ProjectChange = typeof addProject

const applyChange = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  routeState: RouteState,
  response: ServerResponse,
  target: { readonly bot: Bot; readonly byBot: boolean },
  change: ProjectChange,
  projectId: string
): Promise<boolean> => {
  const result = await oneChangeAtATime(services, target.bot.id, async () => {
    const current = await run(services.db.getBot(target.bot.id))
    /* v8 ignore next */
    if (current === undefined) throw new HttpFailure(404, `Bot not found: ${target.bot.id}`)
    return change(services, config.id, current, projectId)
  })
  if (result.notice !== undefined) {
    await appendAndPublish(services.db, fanout, "bot.updated", result.bot.id, {
      id: result.bot.id
    })
    if (!target.byBot) {
      await tellBot(services, fanout, routeState, config.id, result.bot, result.notice).catch(
        swallowError
      )
    }
  }
  writeJson(response, 200, result.bot)
  return true
}

const botForTarget = async (
  services: CodevisorServerServices,
  params: Record<string, string>,
  byBot: boolean
): Promise<{ readonly bot: Bot; readonly byBot: boolean }> => {
  const id = params["id"]!
  if (!byBot) {
    const bot = await run(services.db.getBot(id))
    if (bot === undefined) throw new HttpFailure(404, `Bot not found: ${id}`)
    return { bot, byBot }
  }
  const bot = await run(services.db.findBotOwning({ sessionId: id }))
  if (bot === undefined || !sameId(bot.sessionId, id)) {
    throw new HttpFailure(403, "Only a bot's own chat can change its projects")
  }
  return { bot, byBot }
}

const PROJECT_ROUTES = [
  { collection: "/v1/bots/:id/projects", byBot: false },
  { collection: "/v1/sessions/:id/bot/projects", byBot: true }
] as const

export const routeBotProjects = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  routeState: RouteState,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  for (const { collection, byBot } of PROJECT_ROUTES) {
    const added = matchRouteParams(url.pathname, collection)
    if (added !== undefined && request.method === "POST") {
      const target = await botForTarget(services, added, byBot)
      const payload = await readSchema(request, AddBotProjectRequest)
      return applyChange(
        services,
        config,
        fanout,
        routeState,
        response,
        target,
        addProject,
        payload.projectId
      )
    }
    const removed = matchRouteParams(url.pathname, `${collection}/:projectId`)
    if (removed !== undefined && request.method === "DELETE") {
      const target = await botForTarget(services, removed, byBot)
      return applyChange(
        services,
        config,
        fanout,
        routeState,
        response,
        target,
        removeProject,
        removed["projectId"]!
      )
    }
  }
  return false
}
