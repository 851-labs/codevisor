import { BotImportAction, decode, type Bot, type BotImportSpec } from "@codevisor/api"
import { CloneError } from "@codevisor/worktrees"

import { HttpFailure, run } from "../server-context.js"
import { buildBot, existingBot } from "./bot-create.js"
import { queueHandoff } from "./bot-handoff-queue.js"
import { receiveImportFile, missingImportFiles } from "./bot-import-files.js"
import { writeBotNotes } from "./bot-instructions.js"
import { removeBot } from "./bot-remove.js"
import type { FleetCall } from "./fleet-calls.js"
import { setUpProjectFromGit } from "./project-clone.js"
import type { RouteContext } from "./route-context.js"

export const receiveBotImport = async (
  route: RouteContext,
  call: FleetCall,
  args: unknown
): Promise<unknown> => {
  if (!call.verified) throw new HttpFailure(403, "Only machines on this account can fork bots here")
  const action = importActionOf(args)
  if (action.action === "missing_files") {
    return { fileIds: await missingImportFiles(route.services, action.fileIds) }
  }
  if (action.action === "file") return receiveImportFile(route.services, action)
  if (action.action === "create") return importBot(route, action.bot)

  await queueHandoff(route.services, await importedBotSession(route, action.botId), action.text)
  return { queued: true }
}

const importBot = async (route: RouteContext, spec: BotImportSpec): Promise<Bot> => {
  const existing = await existingBot(route.services, spec.id)
  if (existing !== undefined) return existing

  const projectIds = await localProjectIds(route, spec)
  const bot = await buildBot(route.services, route.config, route.fanout, route.routeState, {
    id: spec.id,
    name: spec.name,
    symbolName: spec.symbolName,
    mascot: spec.mascot,
    harnessId: spec.harnessId,
    configSelections: spec.configSelections,
    projectIds
  })
  try {
    await writeBotNotes(route.services, bot, spec.notes)
    await importConversation(route, bot, spec)
  } catch (cause) {
    await removeBot(route.services, route.config, route.fanout, route.routeState, bot)
    throw cause
  }
  return bot
}

const localProjectIds = async (
  route: RouteContext,
  spec: BotImportSpec
): Promise<ReadonlyArray<string>> => {
  const context = { services: route.services, fanout: route.fanout, serverId: route.config.id }
  const ids: Array<string> = []
  for (const project of spec.projects) {
    const setUp = await setUpProjectFromGit(context, {
      url: project.repoUrl,
      name: project.name
    }).catch(rethrowCloneFailure)
    ids.push(setUp.project.id)
  }
  return ids
}

const rethrowCloneFailure = (cause: unknown): never => {
  if (cause instanceof CloneError) throw new HttpFailure(422, cause.message, cause.code)
  throw cause
}

const importConversation = async (
  route: RouteContext,
  bot: Bot,
  spec: BotImportSpec
): Promise<void> => {
  const changes = await run(route.services.db.importBotMessages(bot.sessionId, spec.messages))
  for (const change of changes) await run(route.fanout.publish(change))
}

const importedBotSession = async (route: RouteContext, botId: string): Promise<string> => {
  const bot = await existingBot(route.services, botId)
  if (bot === undefined) throw new HttpFailure(404, `Bot not found: ${botId}`)
  return bot.sessionId
}

const importActionOf = (args: unknown): BotImportAction => {
  try {
    return decode(BotImportAction)(args)
  } catch {
    throw new HttpFailure(400, "Expected a bot import action")
  }
}
