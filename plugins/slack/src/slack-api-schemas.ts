import { z } from "zod"

const optionalText = z.string().optional()

export const pageCursor = z
  .object({ response_metadata: z.object({ next_cursor: optionalText }).loose().optional() })
  .loose()
  .transform((page) => page.response_metadata?.next_cursor || undefined)

export const identityReply = z
  .object({
    user_id: z.string(),
    user: z.string(),
    team_id: z.string(),
    team: z.string(),
    url: z.string()
  })
  .loose()

export const slackMessage = z
  .object({
    ts: z.string(),
    text: optionalText,
    user: optionalText,
    bot_id: optionalText,
    username: optionalText,
    subtype: optionalText,
    thread_ts: optionalText,
    reply_count: z.number().optional(),
    files: z
      .array(z.object({ id: z.string(), name: optionalText, title: optionalText }).loose())
      .optional(),
    reactions: z.array(z.object({ name: z.string(), count: z.number() }).loose()).optional()
  })
  .loose()
export type SlackMessage = z.infer<typeof slackMessage>

export const messagesReply = z.object({ messages: z.array(slackMessage) }).loose()

const searchPaging = z
  .object({ page: z.number(), page_count: z.number(), total_count: z.number() })
  .loose()
  .optional()

export const messageSearchReply = z
  .object({
    messages: z
      .object({
        matches: z.array(
          slackMessage.extend({
            channel: z.object({ id: z.string(), name: optionalText }).loose(),
            permalink: optionalText
          })
        ),
        pagination: searchPaging
      })
      .loose()
  })
  .loose()

export const fileSearchReply = z
  .object({
    files: z
      .object({
        matches: z.array(
          z
            .object({
              id: z.string(),
              name: optionalText,
              title: optionalText,
              filetype: optionalText,
              permalink: optionalText,
              user: optionalText,
              timestamp: z.number().optional()
            })
            .loose()
        ),
        pagination: searchPaging
      })
      .loose()
  })
  .loose()

export const slackConversation = z
  .object({
    id: z.string(),
    name: optionalText,
    user: optionalText,
    is_im: z.boolean().optional(),
    is_mpim: z.boolean().optional(),
    is_private: z.boolean().optional(),
    is_archived: z.boolean().optional(),
    topic: z.object({ value: z.string() }).loose().optional(),
    purpose: z.object({ value: z.string() }).loose().optional()
  })
  .loose()
export type SlackConversation = z.infer<typeof slackConversation>

export const conversationsReply = z.object({ channels: z.array(slackConversation) }).loose()

export const conversationReply = z.object({ channel: slackConversation }).loose()

export const slackUser = z
  .object({
    id: z.string(),
    name: z.string(),
    real_name: optionalText,
    deleted: z.boolean().optional(),
    is_bot: z.boolean().optional(),
    tz: optionalText,
    profile: z
      .object({
        display_name: optionalText,
        real_name: optionalText,
        email: optionalText,
        title: optionalText
      })
      .loose()
      .optional()
  })
  .loose()
export type SlackUser = z.infer<typeof slackUser>

export const userReply = z.object({ user: slackUser }).loose()

export const usersReply = z.object({ members: z.array(slackUser) }).loose()

export const membersReply = z.object({ members: z.array(z.string()) }).loose()

export const postedReply = z.object({ channel: z.string(), ts: z.string() }).loose()

export const scheduledReply = z
  .object({ channel: z.string(), scheduled_message_id: z.string(), post_at: z.number() })
  .loose()

export const permalinkReply = z.object({ permalink: z.string() }).loose()

export const fileInfoReply = z
  .object({
    file: z
      .object({
        id: z.string(),
        name: optionalText,
        title: optionalText,
        mimetype: optionalText,
        filetype: optionalText,
        size: z.number().optional(),
        url_private_download: optionalText,
        url_private: optionalText,
        permalink: optionalText
      })
      .loose()
  })
  .loose()

export const uploadUrlReply = z.object({ upload_url: z.string(), file_id: z.string() }).loose()
