import type { SlackMessage } from "./slack-api-schemas.js"

export const messageSummary = (message: SlackMessage): Record<string, unknown> => ({
  ts: message.ts,
  ...threadOf(message),
  author: message.user ?? message.username ?? message.bot_id ?? "unknown",
  ...(message.bot_id === undefined ? {} : { bot: true }),
  text: message.text ?? "",
  ...(message.reply_count ? { replies: message.reply_count } : {}),
  ...filesOf(message),
  ...reactionsOf(message)
})

export const mentionedUsers = (text: string): Array<string> =>
  [...text.matchAll(userMentionPattern)].flatMap((match) =>
    match[1] === undefined ? [] : [match[1]]
  )

export const peopleIn = (messages: ReadonlyArray<SlackMessage>): Array<string> =>
  messages.flatMap((message) => [
    ...(message.user === undefined ? [] : [message.user]),
    ...mentionedUsers(message.text ?? "")
  ])

export const mentions = (text: string, userId: string): boolean =>
  mentionedUsers(text).includes(userId)

export const isReply = (ts: string, threadTs: string | undefined): boolean =>
  threadTs !== undefined && threadTs !== ts

export const messageLink = (
  teamUrl: string,
  channel: string,
  ts: string,
  threadTs?: string
): string => {
  const link = new URL(`archives/${channel}/p${ts.replace(".", "")}`, teamUrl)
  if (threadTs !== undefined && isReply(ts, threadTs)) {
    link.searchParams.set("thread_ts", threadTs)
    link.searchParams.set("cid", channel)
  }
  return link.toString()
}

const userMentionPattern = /<@([UW][A-Z0-9]+)(?:\|[^>]*)?>/g

const threadOf = (message: SlackMessage): { threadTs?: string } =>
  message.thread_ts !== undefined && isReply(message.ts, message.thread_ts)
    ? { threadTs: message.thread_ts }
    : {}

const filesOf = (message: SlackMessage) => {
  if (message.files === undefined || message.files.length === 0) return {}

  return {
    files: message.files.map((file) => ({ id: file.id, name: file.title ?? file.name ?? file.id }))
  }
}

const reactionsOf = (message: SlackMessage) => {
  if (message.reactions === undefined || message.reactions.length === 0) return {}

  return {
    reactions: message.reactions.map((reaction) => ({
      emoji: reaction.name,
      count: reaction.count
    }))
  }
}
