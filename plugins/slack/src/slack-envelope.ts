import { z } from "zod"

const optionalText = z.string().optional()

export const messageEvent = z
  .object({
    type: z.literal("message"),
    channel: z.string(),
    ts: z.string(),
    user: optionalText,
    bot_id: optionalText,
    text: optionalText,
    thread_ts: optionalText,
    parent_user_id: optionalText,
    channel_type: z.enum(["channel", "group", "im", "mpim", "app_home"]).optional(),
    subtype: optionalText
  })
  .loose()
export type MessageEvent = z.infer<typeof messageEvent>

export const reactionEvent = z
  .object({
    type: z.literal("reaction_added"),
    user: z.string(),
    reaction: z.string(),
    item_user: optionalText,
    item: z.object({ type: z.string(), channel: optionalText, ts: optionalText }).loose()
  })
  .loose()
export type ReactionEvent = z.infer<typeof reactionEvent>

export const slackEvent = z.discriminatedUnion("type", [messageEvent, reactionEvent])
export type SlackEvent = z.infer<typeof slackEvent>

export type SlackEnvelope = z.infer<typeof slackEnvelope>

export const slackEnvelopeOf = (body: string): SlackEnvelope | undefined => {
  try {
    return slackEnvelope.safeParse(JSON.parse(body)).data
  } catch {
    return undefined
  }
}

const slackEnvelope = z.discriminatedUnion("type", [
  z.object({ type: z.literal("url_verification") }).loose(),
  z.object({ type: z.literal("event_callback"), team_id: z.string(), event: z.unknown() }).loose()
])
