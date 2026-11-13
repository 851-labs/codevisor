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
  HttpFailure,
  matchRoute,
  readSchema,
  run,
  sessionIsArchived,
  swallowError,
  writeJson
} from "../server-context.js"
import { botForChat } from "./bot-turns.js"
import { drainPromptQueue } from "./prompt-queue.js"
import type { RouteContext } from "./route-context.js"
import { attribute } from "./session-event-messages.js"

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
  return false
}

const messageBot = async (route: RouteContext, botId: string): Promise<boolean> => {
  const { services, request, response } = route
  const payload = await readSchema(request, MessageBotRequest)
  const bot = await requireBot(route, botId)
  const text = requireText(payload.text)
  const sender = await requireSender(route, payload.sentByAgentId, payload.sentByAgentMachineId)
  refuseOwnBot(sender, bot)
  if (bot.isArchived) throw new HttpFailure(409, `${bot.name} is archived`)

  const to: ThreadParty = { kind: "bot", botId: bot.id }
  const thread = await run(services.db.openThread(sender.party, to))
  const message = await run(services.db.appendThreadMessage(thread.threadId, sender.party, text))
  await deliverToChat(route, bot.sessionId, threadEvent(message))
  writeJson(response, 200, { sent: true, threadId: thread.threadId, messageId: message.id })
  return true
}

const readThreadWithBot = async (route: RouteContext, botId: string): Promise<boolean> => {
  const { services, response, url } = route
  const bot = await requireBot(route, botId)
  const sender = await requireSender(
    route,
    url.searchParams.get("sentByAgentId") ?? undefined,
    url.searchParams.get("sentByAgentMachineId") ?? undefined
  )
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
  const { services } = route
  const bot = await requireBotChat(route, sessionId)
  const me: ThreadParty = { kind: "bot", botId: bot.id }
  const thread = await requireThreadOf(route, threadId, me)
  const text = requireText(rawText)
  const other = thread.participants.find((participant) => !isParty(participant, me))!
  const chat = await liveChatOf(route, other)
  if (chat === undefined)
    throw new HttpFailure(409, "The other side of this thread is archived or gone")

  const message = await run(services.db.appendThreadMessage(threadId, me, text))
  await deliverToChat(route, chat.id, threadEvent(message))
  return message
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
  party.kind === "bot"
    ? participant.botId === party.botId
    : participant.botId === undefined && participant.agentId === party.agentId

const threadEvent = (message: ThreadMessage): string => {
  const { from } = message
  const who =
    from.botId === undefined
      ? `from="agent" agentId="${attribute(from.agentId)}"`
      : `from="bot" botId="${attribute(from.botId)}"`
  return [
    `<codevisor-event type="thread.message" threadId="${attribute(message.threadId)}" ${who} name="${attribute(from.name)}">`,
    message.text,
    "</codevisor-event>"
  ].join("\n")
}

const deliverToChat = async (
  { services, fanout, routeState, config }: RouteContext,
  sessionId: string,
  text: string
): Promise<void> => {
  await run(services.db.createPromptQueueItem(sessionId, text, [], undefined, undefined, "system"))
  void drainPromptQueue(services, fanout, routeState, config.id, sessionId).catch(swallowError)
}

const liveChatOf = async (
  { services }: RouteContext,
  participant: ThreadParticipant
): Promise<SessionSummary | undefined> => {
  const chat = await run(services.db.getSessionSummary(participant.agentId)).catch(() => undefined)
  if (chat === undefined || (await sessionIsArchived(services, chat))) return undefined
  return chat
}

interface Sender {
  readonly party: ThreadParty
  readonly chat: SessionSummary
}

const requireSender = async (
  { services, config }: RouteContext,
  agentId: string | undefined,
  machineId: string | undefined
): Promise<Sender> => {
  if (agentId === undefined) {
    throw new HttpFailure(
      422,
      "Only a bot or an agent can message a bot this way. The user writes to a bot in the app"
    )
  }
  if (machineId !== undefined && machineId !== config.id) {
    throw new HttpFailure(
      409,
      "Messaging a bot from another machine isn't supported yet. Use agents.message for now"
    )
  }
  const chat = await run(services.db.getSessionSummary(agentId)).catch(() => undefined)
  if (chat === undefined) throw new HttpFailure(404, `Agent not found: ${agentId}`)
  const bot = await botForChat(services, chat.id)
  const party: ThreadParty =
    bot === undefined
      ? { kind: "agent", agentId: chat.id, machineId: config.id }
      : { kind: "bot", botId: bot.id }
  return { party, chat }
}

const refuseOwnBot = (sender: Sender, bot: Bot): void => {
  if (sender.party.kind === "bot" && sender.party.botId === bot.id) {
    throw new HttpFailure(409, "A bot can't message itself")
  }
  const { createdByAgentId, isDetached } = sender.chat
  if (createdByAgentId?.toLowerCase() === bot.sessionId.toLowerCase() && isDetached !== true) {
    throw new HttpFailure(
      409,
      `${bot.name} started you and already gets your reply when your turn ends. Put what it needs in your final message`
    )
  }
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
