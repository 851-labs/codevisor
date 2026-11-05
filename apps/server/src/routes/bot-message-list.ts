import type { BotMessage, BotMessageSender } from "@codevisor/api"

import { HttpFailure, run, type CodevisorServerServices } from "../server-context.js"

export interface ListedBotMessage {
  readonly sender: BotMessageSender
  readonly text: string
  readonly attachments?: ReadonlyArray<string>
  readonly sentAt: string
}

export interface BotMessageList {
  readonly messages: ReadonlyArray<ListedBotMessage>
  readonly next?: number
}

export const listedBotMessages = async (
  services: CodevisorServerServices,
  sessionId: string,
  query: URLSearchParams
): Promise<BotMessageList> => {
  const page = await run(
    services.db.listBotMessages(sessionId, before(query), limit(query), sender(query))
  )
  const messages = page.messages.map(listed)

  const oldest = page.messages[0]
  if (!page.hasMore || oldest === undefined) return { messages }
  return { messages, next: oldest.sequence }
}

const defaultLimit = 10
const maxLimit = 50
const senders: ReadonlyArray<BotMessageSender> = ["user", "bot", "notice"]

const limit = (query: URLSearchParams): number => {
  const parsed = Number.parseInt(query.get("limit") ?? "", 10)
  if (!Number.isFinite(parsed) || parsed < 1) return defaultLimit
  return Math.min(parsed, maxLimit)
}

const before = (query: URLSearchParams): number | undefined => {
  const parsed = Number.parseInt(query.get("before") ?? "", 10)
  return Number.isFinite(parsed) ? parsed : undefined
}

const sender = (query: URLSearchParams): BotMessageSender | undefined => {
  const raw = query.get("sender")
  if (raw === null) return undefined
  const known = senders.find((candidate) => candidate === raw)
  if (known === undefined) throw new HttpFailure(422, `sender must be one of ${senders.join(", ")}`)
  return known
}

const listed = (message: BotMessage): ListedBotMessage => {
  const names = (message.attachments ?? []).map((attachment) => attachment.name)
  return {
    sender: message.sender,
    text: message.text,
    ...(names.length === 0 ? {} : { attachments: names }),
    sentAt: message.createdAt
  }
}
