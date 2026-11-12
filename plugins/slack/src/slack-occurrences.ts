import type { EventOccurrence } from "@codevisor/plugin-kit"

import { conversationType, type SlackDirectory, type SlackIdentity } from "./slack-directory.js"
import { type MessageEvent, type ReactionEvent, slackEvent } from "./slack-envelope.js"
import { slackEvents } from "./slack-event-catalog.js"
import { isReply, mentions, messageLink } from "./slack-messages.js"

export interface FeedContext {
  me: SlackIdentity
  directory: SlackDirectory
}

export const occurrencesFor = async (
  event: unknown,
  feed: FeedContext
): Promise<Array<EventOccurrence>> => {
  const parsed = slackEvent.safeParse(event).data
  if (parsed === undefined) return []
  if (parsed.type === "message") return messageOccurrences(parsed, feed)

  return reactionOccurrences(parsed, feed)
}

const messageOccurrences = async (
  event: MessageEvent,
  feed: FeedContext
): Promise<Array<EventOccurrence>> => {
  const author = event.user ?? event.bot_id
  if (!relayedSubtypes.has(event.subtype) || author === undefined || author === feed.me.userId)
    return []

  const payload = await messagePayload(event, author, feed)
  return messageEventNames(payload).map((name) =>
    occurrence(name, `${event.channel}:${event.ts}`, event.ts, payload)
  )
}

const relayedSubtypes = new Set([
  undefined,
  "thread_broadcast",
  "file_share",
  "bot_message",
  "me_message"
])

interface MessagePayload extends Record<string, unknown> {
  channel: { id: string; name: string | null; type: string }
  mentionsMe: boolean
  inMyThread: boolean
}

const messagePayload = async (
  event: MessageEvent,
  author: string,
  feed: FeedContext
): Promise<MessagePayload> => {
  const text = event.text ?? ""
  const reply = isReply(event.ts, event.thread_ts)
  return {
    text,
    ts: event.ts,
    threadTs: event.thread_ts ?? null,
    link: messageLink(feed.me.url, event.channel, event.ts, event.thread_ts),
    channel: await channelPayload(event.channel, channelTypes[event.channel_type ?? ""], feed),
    author: await personPayload(author, event.user === undefined, feed),
    bot: event.bot_id !== undefined || event.subtype === "bot_message",
    mentionsMe: mentions(text, feed.me.userId),
    isReply: reply,
    inMyThread: reply && event.parent_user_id === feed.me.userId
  }
}

const channelTypes: Readonly<Record<string, string>> = {
  channel: "public",
  group: "private",
  im: "dm",
  mpim: "group_dm"
}

const messageEventNames = (payload: MessagePayload): Array<string> => [
  slackEvents.messagePosted,
  ...(payload.mentionsMe ? [slackEvents.mentionCreated] : []),
  ...(isDirect(payload.channel.type) ? [slackEvents.dmReceived] : []),
  ...(payload.inMyThread ? [slackEvents.threadReplied] : [])
]

const isDirect = (type: string): boolean => type === "dm" || type === "group_dm"

const reactionOccurrences = async (
  event: ReactionEvent,
  feed: FeedContext
): Promise<Array<EventOccurrence>> => {
  const { channel, ts } = event.item
  if (!reactsToMyMessage(event, feed.me.userId) || channel === undefined || ts === undefined)
    return []

  const payload = {
    reaction: event.reaction,
    ts,
    link: messageLink(feed.me.url, channel, ts),
    channel: await channelPayload(channel, undefined, feed),
    author: await personPayload(event.user, false, feed)
  }
  return [
    occurrence(
      slackEvents.reactionAdded,
      `${channel}:${ts}:${event.user}:${event.reaction}`,
      ts,
      payload
    )
  ]
}

const reactsToMyMessage = (event: ReactionEvent, me: string): boolean =>
  event.item.type === "message" && event.item_user === me && event.user !== me

const channelPayload = async (id: string, knownType: string | undefined, feed: FeedContext) => {
  const conversation = await feed.directory.conversation(id)
  return {
    id,
    name: await feed.directory.conversationName(id),
    type: knownType ?? (conversation === null ? "public" : conversationType(conversation))
  }
}

const personPayload = async (id: string, isBotId: boolean, feed: FeedContext) => {
  if (isBotId) return { id, name: null }

  return { id, name: await feed.directory.personName(id) }
}

const occurrence = (
  name: string,
  key: string,
  ts: string,
  data: Record<string, unknown>
): EventOccurrence => ({
  eventId: `${name}:${key}`,
  name,
  timestamp: new Date(Number.parseFloat(ts) * millisecondsPerSecond).toISOString(),
  data,
  cursor: null
})

const millisecondsPerSecond = 1000
