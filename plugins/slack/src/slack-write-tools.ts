import { permalinkReply, postedReply, scheduledReply } from "./slack-api-schemas.js"
import { SlackToolError } from "./slack-directory.js"
import {
  confirmationRequired,
  postArguments,
  reactionArguments,
  scheduleArguments
} from "./slack-tool-arguments.js"
import type { ToolContext, ToolRunner } from "./slack-tool-runner.js"

export const addReaction: ToolRunner = async (args, context) =>
  react("reactions.add", args, context)

export const removeReaction: ToolRunner = async (args, context) =>
  react("reactions.remove", args, context)

export const postMessage: ToolRunner = async (args, { api, directory }) => {
  const { channel, text, threadTs, broadcast, confirm } = postArguments.parse(args)
  requireConfirmation("post_message", confirm)

  const id = await directory.resolveConversation(channel)
  const posted = postedReply.parse(
    await api.call("chat.postMessage", {
      channel: id,
      text,
      thread_ts: threadTs,
      ...(threadTs !== undefined && broadcast ? { reply_broadcast: true } : {})
    })
  )
  return { posted: true, channel: posted.channel, ts: posted.ts, ...(await linkTo(api, posted)) }
}

export const scheduleMessage: ToolRunner = async (args, { api, directory }) => {
  const { channel, text, postAt, threadTs, confirm } = scheduleArguments.parse(args)
  requireConfirmation("schedule_message", confirm)

  const id = await directory.resolveConversation(channel)
  const scheduled = scheduledReply.parse(
    await api.call("chat.scheduleMessage", {
      channel: id,
      text,
      post_at: Math.floor(Date.parse(postAt) / millisecondsPerSecond),
      thread_ts: threadTs
    })
  )
  return {
    scheduled: true,
    channel: scheduled.channel,
    id: scheduled.scheduled_message_id,
    postAt: new Date(scheduled.post_at * millisecondsPerSecond).toISOString()
  }
}

export const requireConfirmation = (tool: string, confirm: boolean): void => {
  if (!confirm) throw new SlackToolError(confirmationRequired(tool))
}

const millisecondsPerSecond = 1000

const react = async (
  method: string,
  args: Record<string, unknown>,
  { api, directory }: ToolContext
) => {
  const { channel, ts, emoji } = reactionArguments.parse(args)
  await api.call(method, {
    channel: await directory.resolveConversation(channel),
    timestamp: ts,
    name: emoji
  })
  return { ok: true, emoji }
}

const linkTo = async (api: ToolContext["api"], posted: { channel: string; ts: string }) =>
  api.call("chat.getPermalink", { channel: posted.channel, message_ts: posted.ts }).then(
    (body) => ({ link: permalinkReply.parse(body).permalink }),
    () => ({})
  )
