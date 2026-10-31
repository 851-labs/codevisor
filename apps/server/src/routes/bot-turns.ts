import type { Bot, BotMessage } from "@codevisor/api"
import type { AppendBotMessageRecord } from "@codevisor/db"

import {
  appendAndPublish,
  run,
  type CodevisorServerServices,
  type EventFanout
} from "../server-context.js"

export const botForChat = async (
  services: CodevisorServerServices,
  sessionId: string
): Promise<Bot | undefined> => {
  const bot = await run(services.db.findBotOwning({ sessionId }))
  return bot?.sessionId.toLowerCase() === sessionId.toLowerCase() ? bot : undefined
}

export const conversationalBotForSession = async (
  services: CodevisorServerServices,
  sessionId: string
): Promise<Bot | undefined> => {
  const bot = await botForChat(services, sessionId)
  return bot?.conversational === true ? bot : undefined
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
  return message
}
