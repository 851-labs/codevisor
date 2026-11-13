import type { IncomingMessage, ServerResponse } from "node:http"

import { ForkBotRequest as ForkBotRequestSchema } from "@codevisor/api"
import type { Bot, ForkBotRequest } from "@codevisor/api"

import {
  readSchema,
  run,
  writeJson,
  type CodevisorServerConfig,
  type CodevisorServerServices,
  type EventFanout,
  type RouteState
} from "../server-context.js"
import { buildBot, existingBot, type BotSpec } from "./bot-create.js"
import { forkHandoffText } from "./bot-fork-handoff.js"
import { forkableBot, forkSpec, movedAgents, type BotFork } from "./bot-fork-parts.js"
import { forkBotToMachine, forkTargetMachine } from "./bot-fork-remote.js"
import { queueHandoff } from "./bot-handoff-queue.js"
import { copyBotNotes } from "./bot-instructions.js"
import { removeBot } from "./bot-remove.js"

export const forkBot = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  routeState: RouteState,
  sourceId: string,
  request: IncomingMessage,
  response: ServerResponse
): Promise<boolean> => {
  const fork: BotFork = { services, config, fanout, routeState }
  const payload = await readSchema(request, ForkBotRequestSchema)
  const target = await forkTargetMachine(fork, payload.toMachine)
  if (target !== undefined) {
    writeJson(response, 201, await forkBotToMachine(fork, { sourceId, payload, target }))
    return true
  }

  const existing = await existingBot(services, payload.id)
  if (existing !== undefined) {
    writeJson(response, 200, existing)
    return true
  }

  const source = await forkableBot(services, sourceId)
  writeJson(response, 201, await forkHere(fork, source, forkSpec(source, payload), payload))
  return true
}

const forkHere = async (
  fork: BotFork,
  source: Bot,
  spec: BotSpec,
  payload: ForkBotRequest
): Promise<Bot> => {
  const { services, config, fanout, routeState } = fork
  const forked = await buildBot(services, config, fanout, routeState, spec)
  try {
    await copyBotNotes(services, source, forked)
    await copyConversation(services, fanout, source, forked)
  } catch (cause) {
    await removeBot(services, config, fanout, routeState, forked)
    throw cause
  }

  const agents = await movedAgents(fork, payload, {
    fromAgentId: source.sessionId,
    toAgentId: forked.sessionId
  })
  const handoff = { source, targetHarnessId: forked.harnessId, agents }
  await queueHandoff(
    services,
    forked.sessionId,
    await forkHandoffText(services, routeState, handoff)
  )
  return forked
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
