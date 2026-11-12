import { emptyArguments, type EventType } from "@codevisor/plugin-kit"

export const slackEvents = {
  messagePosted: "message.posted",
  mentionCreated: "mention.created",
  dmReceived: "dm.received",
  threadReplied: "thread.replied",
  reactionAdded: "reaction.added"
} as const

export const slackIngress = { name: "slack", title: "Slack events URL" }

const text = { type: "string" }
const flag = { type: "boolean" }
const nullableText = { type: ["string", "null"] }

const record = (properties: Record<string, unknown>) => ({
  type: "object",
  properties,
  required: Object.keys(properties)
})

const channel = record({
  id: text,
  name: nullableText,
  type: { type: "string", enum: ["public", "private", "dm", "group_dm"] }
})

const person = record({ id: text, name: nullableText })

const message = {
  text,
  ts: text,
  threadTs: nullableText,
  link: text,
  channel,
  author: person,
  bot: flag,
  mentionsMe: flag,
  isReply: flag,
  inMyThread: flag
}

const pushEvent = (
  name: string,
  title: string,
  description: string,
  payload: Record<string, unknown>
): EventType => ({
  name,
  title,
  description,
  delivery: ["push"],
  inputSchema: emptyArguments,
  payloadSchema: record(payload)
})

export const slackEventTypes: ReadonlyArray<EventType> = [
  pushEvent(
    slackEvents.messagePosted,
    "New message",
    'Someone else posted in a conversation you\'re in. Filter it: busy workspaces post a lot. For example channel.name == "incidents" or text.contains("deploy").',
    message
  ),
  pushEvent(
    slackEvents.mentionCreated,
    "Mentioned",
    "Someone else @-mentioned you in a message.",
    message
  ),
  pushEvent(
    slackEvents.dmReceived,
    "Direct message",
    "Someone sent you a DM or wrote in a group DM you're in. channel.type is dm or group_dm.",
    message
  ),
  pushEvent(
    slackEvents.threadReplied,
    "Thread reply",
    "Someone else replied in a thread you started.",
    message
  ),
  pushEvent(
    slackEvents.reactionAdded,
    "Reaction",
    "Someone reacted to one of your messages. reaction is the emoji name, such as white_check_mark.",
    { reaction: text, ts: text, link: text, channel, author: person }
  )
]
