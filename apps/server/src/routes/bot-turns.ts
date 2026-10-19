import type { Bot, BotMessage, PromptOrigin } from "@codevisor/api"
import type { AppendBotMessageRecord } from "@codevisor/db"

import {
  appendAndPublish,
  run,
  type CodevisorServerServices,
  type EventFanout
} from "../server-context.js"

interface BotTurn {
  userPrompted: boolean
  sent: boolean
}

const botTurns = new WeakMap<CodevisorServerServices, Map<string, BotTurn>>()

const turnsFor = (services: CodevisorServerServices): Map<string, BotTurn> => {
  let turns = botTurns.get(services)
  if (turns === undefined) {
    turns = new Map()
    botTurns.set(services, turns)
  }
  return turns
}

const turnFor = (services: CodevisorServerServices, sessionId: string): BotTurn => {
  const turns = turnsFor(services)
  const key = sessionId.toLowerCase()
  let turn = turns.get(key)
  if (turn === undefined) {
    turn = { userPrompted: false, sent: false }
    turns.set(key, turn)
  }
  return turn
}

export const conversationalBotForSession = async (
  services: CodevisorServerServices,
  sessionId: string
): Promise<Bot | undefined> => {
  const bot = await run(services.db.findBotOwning({ sessionId }))
  return bot !== undefined &&
    bot.conversational &&
    bot.sessionId.toLowerCase() === sessionId.toLowerCase()
    ? bot
    : undefined
}

export const postBotMessage = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  sessionId: string,
  record: AppendBotMessageRecord
): Promise<BotMessage> => {
  const { message, created } = await run(services.db.appendBotMessage(sessionId, record))
  if (created) {
    await appendAndPublish(services.db, fanout, "bot.message", sessionId, { message })
  }
  if (record.sender === "bot") turnFor(services, sessionId).sent = true
  return message
}

export const noteBotPrompt = (
  services: CodevisorServerServices,
  sessionId: string,
  origin: PromptOrigin | undefined
): void => {
  if (origin !== "system") turnFor(services, sessionId).userPrompted = true
}

export const takeBotTurn = (
  services: CodevisorServerServices,
  sessionId: string
): BotTurn | undefined => {
  const turns = turnsFor(services)
  const key = sessionId.toLowerCase()
  const turn = turns.get(key)
  turns.delete(key)
  return turn
}
