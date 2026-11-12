import { z } from "zod"

import {
  maxListedChannels,
  maxListedMembers,
  maxReadMessages,
  maxSearchResults
} from "./slack-tool-catalog.js"

export const confirmationRequired = (tool: string): string =>
  `${tool} requires confirm: true. Show the user the exact text and where it goes, and get their explicit approval first.`

const reference = z.string().trim().min(1)
const ts = z.string().regex(/^\d+\.\d+$/, "Use a Slack message ts, such as 1731350000.123400.")
const cursor = z.string().min(1).optional()
const page = z.number().int().min(1).default(1)

const slackTime = z
  .string()
  .trim()
  .transform((value, context) => {
    const seconds = secondsOf(value)
    if (seconds === undefined)
      context.addIssue({ code: "custom", message: `${value} isn't a ts or ISO time.` })
    return seconds ?? ""
  })

const secondsOf = (value: string): string | undefined => {
  if (/^\d+(\.\d+)?$/.test(value)) return value
  const parsed = Date.parse(value)
  return Number.isNaN(parsed) ? undefined : String(parsed / millisecondsPerSecond)
}

const millisecondsPerSecond = 1000

export const searchArguments = z.object({
  query: z.string().trim().min(1),
  sort: z.enum(["newest", "relevance"]).default("newest"),
  count: z.number().int().min(1).max(maxSearchResults).default(20),
  page
})

export const fileSearchArguments = searchArguments.omit({ sort: true })

export const channelTypes = {
  public: "public_channel",
  private: "private_channel",
  dm: "im",
  group_dm: "mpim"
}

export const listChannelsArguments = z.object({
  query: z.string().trim().optional(),
  types: z
    .array(z.enum(["public", "private", "dm", "group_dm"]))
    .min(1)
    .default(["public", "private"]),
  limit: z.number().int().min(1).max(maxListedChannels).default(100),
  cursor
})

export const findUsersArguments = z.object({ query: z.string().trim().min(1) })

export const getUserArguments = z.object({ user: reference })

export const readChannelArguments = z.object({
  channel: reference,
  limit: z.number().int().min(1).max(maxReadMessages).default(30),
  oldest: slackTime.optional(),
  latest: slackTime.optional(),
  cursor
})

export const readThreadArguments = z.object({
  channel: reference,
  ts,
  limit: z.number().int().min(1).max(maxReadMessages).default(50),
  cursor
})

export const membersArguments = z.object({
  channel: reference,
  limit: z.number().int().min(1).max(maxListedMembers).default(50),
  cursor
})

export const fileArguments = z.object({
  file: z.string().regex(/^F[A-Z0-9]+$/, "Use a Slack file id (F…).")
})

export const reactionArguments = z.object({
  channel: reference,
  ts,
  emoji: z
    .string()
    .trim()
    .transform((name) => name.replaceAll(":", ""))
    .pipe(z.string().min(1))
})

const approved = { confirm: z.boolean() }

export const postArguments = z.object({
  channel: reference,
  text: z.string().trim().min(1),
  threadTs: ts.optional(),
  broadcast: z.boolean().default(false),
  ...approved
})

export const scheduleArguments = z.object({
  channel: reference,
  text: z.string().trim().min(1),
  postAt: z.iso.datetime({ offset: true }),
  threadTs: ts.optional(),
  ...approved
})

export const uploadArguments = z.object({
  channel: reference,
  path: z.string().trim().startsWith("/", "Use an absolute path."),
  title: z.string().trim().min(1).optional(),
  comment: z.string().trim().min(1).optional(),
  threadTs: ts.optional(),
  ...approved
})
