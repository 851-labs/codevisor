import { randomUUID } from "node:crypto"

import type { Bot, ForkBotRequest, SessionSummary } from "@codevisor/api"

import {
  HttpFailure,
  run,
  type CodevisorServerConfig,
  type CodevisorServerServices,
  type EventFanout,
  type RouteState
} from "../server-context.js"
import { moveBotAgents, type AgentsMove } from "./bot-agents-move.js"
import type { BotSpec } from "./bot-create.js"

export interface BotFork {
  readonly services: CodevisorServerServices
  readonly config: CodevisorServerConfig
  readonly fanout: EventFanout
  readonly routeState: RouteState
}

export const forkSpec = (source: Bot, payload: ForkBotRequest): BotSpec => ({
  id: (payload.id ?? randomUUID()).toLowerCase(),
  name: payload.name ?? `${source.name}${forkSuffix}`,
  symbolName: source.symbolName,
  mascot: payload.mascot ?? source.mascot,
  harnessId: payload.harnessId,
  configSelections: payload.configSelections,
  projectIds: source.projects.map((project) => project.projectId)
})

const forkSuffix = " (fork)"

export const forkableBot = async (services: CodevisorServerServices, id: string): Promise<Bot> => {
  const bot = await run(services.db.getBot(id))
  if (bot === undefined) throw new HttpFailure(404, `Bot not found: ${id}`)
  if (bot.isArchived) throw new HttpFailure(409, "Unarchive this bot before forking it")
  return bot
}

export const movedAgents = async (
  fork: BotFork,
  payload: ForkBotRequest,
  move: AgentsMove
): Promise<ReadonlyArray<SessionSummary>> => {
  if (payload.moveAgents === false) return []

  return moveBotAgents(fork.services, fork.fanout, fork.config.id, move)
}
