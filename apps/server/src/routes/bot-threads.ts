import {
  MessageBotRequest,
  type Bot,
  type SessionSummary,
  type Thread,
  type ThreadMessage,
  type ThreadParticipant
} from "@codevisor/api"
import type { ThreadParty } from "@codevisor/db"

import {
  appendAndPublish,
  HttpFailure,
  matchRoute,
  readSchema,
  run,
  sessionIsArchived,
  writeJson
} from "../server-context.js"
import { botForChat } from "./bot-turns.js"
import type { RouteContext } from "./route-context.js"
import { announceThreadMessage, isOnAnotherMachine } from "./thread-delivery.js"
import { refuseOwnBot, requireSender } from "./thread-senders.js"

const DEFAULT_LIMIT = 10
const MAX_LIMIT = 50

export interface ListedThreadMessage {
  readonly from: string
  readonly mine: boolean
  readonly text: string
  readonly sentAt: string
}

export interface ThreadMessageList {
  readonly messages: ReadonlyArray<ListedThreadMessage>
  readonly next?: number
}

export const routeBotThreads = async (route: RouteContext): Promise<boolean> => {
  const { request, url } = route
  const botId = matchRoute(url.pathname, "/v1/bots/:id/messages")
  if (botId !== undefined && request.method === "POST") return messageBot(route, botId)
  if (botId !== undefined && request.method === "GET") return readThreadWithBot(route, botId)

  const sessionId = matchRoute(url.pathname, "/v1/sessions/:id/threads")
  if (sessionId !== undefined && request.method === "GET") return listBotThreads(route, sessionId)

  const ofBotId = matchRoute(url.pathname, "/v1/bots/:id/threads")
  if (ofBotId !== undefined && request.method === "GET") return showBotThreads(route, ofBotId)
  const threadId = matchRoute(url.pathname, "/v1/threads/:id/messages")
  if (threadId !== undefined && request.method === "GET") return showThreadMessages(route, threadId)
  return false
}

const showBotThreads = async (route: RouteContext, botId: string): Promise<boolean> => {
  const { services, response } = route
  const bot = await requireBot(route, botId)
  writeJson(response, 200, await run(services.db.listThreads({ kind: "bot", botId: bot.id })))
  return true
}

const showThreadMessages = async (route: RouteContext, threadId: string): Promise<boolean> => {
  const { services, response, url } = route
  if ((await run(services.db.getThread(threadId))) === undefined) {
    throw new HttpFailure(404, `Thread not found: ${threadId}`)
  }
  const query = url.searchParams
  writeJson(
    response,
    200,
    await run(services.db.listThreadMessages(threadId, before(query), limit(query)))
  )
  return true
}

const messageBot = async (route: RouteContext, botId: string): Promise<boolean> => {
  const { services, request, response } = route
  const payload = await readSchema(request, MessageBotRequest)
  const bot = await requireBot(route, botId)
  const text = requireText(payload.text)
  const sender = await requireSender(route, {
    agentId: payload.sentByAgentId,
    machineId: payload.sentByAgentMachineId,
    botId: payload.sentByBotId,
    name: payload.sentByName,
    createdByAgentId: payload.senderCreatedByAgentId,
    createdByAgentMachineId: payload.senderCreatedByAgentMachineId
  })
  refuseOwnBot(route, sender, bot)
  if (bot.isArchived) throw new HttpFailure(409, `${bot.name} is archived`)

  const to: ThreadParty = { kind: "bot", botId: bot.id }
  const thread = await run(services.db.openThread(sender.party, to))
  const message = await postThreadMessage(route, thread, sender.party, text)
  writeJson(response, 200, { sent: true, threadId: thread.threadId, messageId: message.id })
  return true
}

const readThreadWithBot = async (route: RouteContext, botId: string): Promise<boolean> => {
  const { services, response, url } = route
  const bot = await requireBot(route, botId)
  const sender = await requireSender(route, {
    agentId: url.searchParams.get("sentByAgentId") ?? undefined,
    machineId: url.searchParams.get("sentByAgentMachineId") ?? undefined
  })
  const thread = await run(services.db.findThread(sender.party, { kind: "bot", botId: bot.id }))
  if (thread === undefined) {
    writeJson(response, 200, { messages: [] })
    return true
  }
  const list = await listedThreadMessages(route, thread, sender.party, url.searchParams)
  writeJson(response, 200, { threadId: thread.threadId, ...list })
  return true
}

const listBotThreads = async (route: RouteContext, sessionId: string): Promise<boolean> => {
  const { services, response } = route
  const bot = await requireBotChat(route, sessionId)
  const me: ThreadParty = { kind: "bot", botId: bot.id }
  const threads = await run(services.db.listThreads(me))
  writeJson(response, 200, { threads: threads.map((thread) => listedThread(thread, me)) })
  return true
}

export const sendThreadMessage = async (
  route: RouteContext,
  sessionId: string,
  threadId: string,
  rawText: string
): Promise<ThreadMessage> => {
  const bot = await requireBotChat(route, sessionId)
  const me: ThreadParty = { kind: "bot", botId: bot.id }
  const thread = await requireThreadOf(route, threadId, me)
  const text = requireText(rawText)
  const other = thread.participants.find((participant) => !isParty(participant, me))!
  if (!isOnAnotherMachine(route, other) && (await liveChatOf(route, other)) === undefined) {
    throw new HttpFailure(409, "The other side of this thread is archived or gone")
  }
  return postThreadMessage(route, thread, me, text)
}

export const listedThreadOfBot = async (
  route: RouteContext,
  sessionId: string,
  threadId: string
): Promise<ThreadMessageList> => {
  const bot = await requireBotChat(route, sessionId)
  const me: ThreadParty = { kind: "bot", botId: bot.id }
  const thread = await requireThreadOf(route, threadId, me)
  return listedThreadMessages(route, thread, me, route.url.searchParams)
}

const postThreadMessage = async (
  route: RouteContext,
  thread: Thread,
  from: ThreadParty,
  text: string
): Promise<ThreadMessage> => {
  const { services, fanout } = route
  const { message } = await run(services.db.appendThreadMessage(thread.threadId, from, { text }))
  await appendAndPublish(services.db, fanout, "thread.message", thread.threadId, { message })
  await announceThreadMessage(route, thread, message)
  return message
}

const listedThreadMessages = async (
  { services }: RouteContext,
  thread: Thread,
  me: ThreadParty,
  query: URLSearchParams
): Promise<ThreadMessageList> => {
  const page = await run(
    services.db.listThreadMessages(thread.threadId, before(query), limit(query))
  )
  const messages = page.messages.map((message) => listedMessage(message, me))
  const oldest = page.messages[0]
  if (!page.hasMore || oldest === undefined) return { messages }
  return { messages, next: oldest.sequence }
}

const listedMessage = (message: ThreadMessage, me: ThreadParty): ListedThreadMessage => ({
  from: message.from.name,
  mine: isParty(message.from, me),
  text: message.text,
  sentAt: message.createdAt
})

const listedThread = (thread: Thread, me: ThreadParty) => {
  const other = thread.participants.find((participant) => !isParty(participant, me))!
  return {
    threadId: thread.threadId,
    with: other,
    ...(thread.lastMessage === undefined
      ? {}
      : { lastMessage: listedMessage(thread.lastMessage, me) })
  }
}

const isParty = (participant: ThreadParticipant, party: ThreadParty): boolean =>
  party.kind === "agent"
    ? participant.botId === undefined && participant.agentId === party.agentId
    : participant.botId === party.botId

const liveChatOf = async (
  { services }: RouteContext,
  participant: ThreadParticipant
): Promise<SessionSummary | undefined> => {
  const chat = await run(services.db.getSessionSummary(participant.agentId)).catch(() => undefined)
  if (chat === undefined || (await sessionIsArchived(services, chat))) return undefined
  return chat
}

const requireBot = async ({ services }: RouteContext, botId: string): Promise<Bot> => {
  const bot = await run(services.db.getBot(botId))
  if (bot === undefined) throw new HttpFailure(404, `Bot not found: ${botId}`)
  return bot
}

const requireBotChat = async ({ services }: RouteContext, sessionId: string): Promise<Bot> => {
  const bot = await botForChat(services, sessionId)
  if (bot === undefined) throw new HttpFailure(403, "Only a bot has threads")
  return bot
}

const requireThreadOf = async (
  { services }: RouteContext,
  threadId: string,
  me: ThreadParty
): Promise<Thread> => {
  const thread = await run(services.db.getThread(threadId))
  if (
    thread === undefined ||
    !thread.participants.some((participant) => isParty(participant, me))
  ) {
    throw new HttpFailure(404, `Thread not found: ${threadId}`)
  }
  return thread
}

const requireText = (raw: string): string => {
  const text = raw.trim()
  if (text.length === 0) throw new HttpFailure(422, "A message needs text")
  return text
}

const limit = (query: URLSearchParams): number => {
  const parsed = Number.parseInt(query.get("limit") ?? "", 10)
  if (!Number.isFinite(parsed) || parsed < 1) return DEFAULT_LIMIT
  return Math.min(parsed, MAX_LIMIT)
}

const before = (query: URLSearchParams): number | undefined => {
  const parsed = Number.parseInt(query.get("before") ?? "", 10)
  return Number.isFinite(parsed) ? parsed : undefined
}
