import { randomUUID } from "node:crypto"
import type { IncomingMessage, ServerResponse } from "node:http"

import { ForkBotRequest as ForkBotRequestSchema } from "@codevisor/api"
import type { Bot, ForkBotRequest, SessionSummary } from "@codevisor/api"

import {
  HttpFailure,
  readSchema,
  run,
  writeJson,
  type CodevisorServerConfig,
  type CodevisorServerServices,
  type EventFanout,
  type RouteState
} from "../server-context.js"
import { sessionIsArchived } from "../server-workspace-effects.js"
import { moveBotAgents } from "./bot-agents-move.js"
import { buildBot, existingBot, type BotSpec } from "./bot-create.js"
import { queueHandoff } from "./bot-handoff-queue.js"
import {
  HANDOFF_MESSAGE_LIMIT,
  handoffText,
  type BotHandoff,
  type HandoffAgent
} from "./bot-handoff-text.js"
import { copyBotNotes } from "./bot-instructions.js"
import { removeBot } from "./bot-remove.js"
import { hasLiveTurn } from "./prompt-queue.js"

export const forkBot = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  routeState: RouteState,
  sourceId: string,
  request: IncomingMessage,
  response: ServerResponse
): Promise<boolean> => {
  const payload = await readSchema(request, ForkBotRequestSchema)
  const existing = await existingBot(services, payload.id)
  if (existing !== undefined) {
    writeJson(response, 200, existing)
    return true
  }

  const source = await forkableBot(services, sourceId)
  const fork = await buildBot(services, config, fanout, routeState, forkSpec(source, payload))
  try {
    await copyBotNotes(services, source, fork)
    await copyConversation(services, fanout, source, fork)
  } catch (cause) {
    await removeBot(services, config, fanout, routeState, fork)
    throw cause
  }

  const agents = await movedAgents(services, fanout, config.id, { source, fork, payload })
  const handoff = await handoffFor(services, routeState, { source, fork, agents })
  await queueHandoff(services, fork.sessionId, handoffText(handoff))
  writeJson(response, 201, fork)
  return true
}

const copyConversation = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  source: Bot,
  fork: Bot
): Promise<void> => {
  const changes = await run(services.db.copyBotMessages(source.sessionId, fork.sessionId))
  for (const change of changes) await run(fanout.publish(change))
}

interface ForkParts {
  readonly source: Bot
  readonly fork: Bot
}

const forkableBot = async (services: CodevisorServerServices, id: string): Promise<Bot> => {
  const bot = await run(services.db.getBot(id))
  if (bot === undefined) throw new HttpFailure(404, `Bot not found: ${id}`)
  if (bot.isArchived) throw new HttpFailure(409, "Unarchive this bot before forking it")
  return bot
}

const forkSpec = (source: Bot, payload: ForkBotRequest): BotSpec => ({
  id: (payload.id ?? randomUUID()).toLowerCase(),
  name: payload.name ?? `${source.name}${forkSuffix}`,
  symbolName: source.symbolName,
  mascot: payload.mascot ?? source.mascot,
  harnessId: payload.harnessId,
  configSelections: payload.configSelections,
  projectIds: source.projects.map((project) => project.projectId)
})

const forkSuffix = " (fork)"

const movedAgents = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  parts: ForkParts & { readonly payload: ForkBotRequest }
): Promise<ReadonlyArray<SessionSummary>> => {
  if (parts.payload.moveAgents === false) return []

  return moveBotAgents(services, fanout, serverId, {
    fromAgentId: parts.source.sessionId,
    toAgentId: parts.fork.sessionId
  })
}

const handoffFor = async (
  services: CodevisorServerServices,
  routeState: RouteState,
  parts: ForkParts & { readonly agents: ReadonlyArray<SessionSummary> }
): Promise<BotHandoff> => ({
  sourceName: parts.source.name,
  sourceHarness: harnessName(services, parts.source.harnessId),
  targetHarness: harnessName(services, parts.fork.harnessId),
  messages: await recentMessages(services, parts.source),
  agents: await handoffAgents(services, routeState, parts.agents)
})

const harnessName = (services: CodevisorServerServices, harnessId: string): string =>
  services.agents.catalog.find((definition) => definition.id === harnessId)?.name ?? harnessId

const recentMessages = async (services: CodevisorServerServices, bot: Bot) => {
  const page = await run(
    services.db.listBotMessages(bot.sessionId, undefined, HANDOFF_MESSAGE_LIMIT)
  )
  return page.messages
}

const handoffAgents = async (
  services: CodevisorServerServices,
  routeState: RouteState,
  agents: ReadonlyArray<SessionSummary>
): Promise<ReadonlyArray<HandoffAgent>> => {
  const active: Array<HandoffAgent> = []
  for (const agent of agents) {
    if (await sessionIsArchived(services, agent)) continue
    active.push({ id: agent.id, title: agent.title, isWorking: hasLiveTurn(routeState, agent.id) })
  }
  return active
}
