import { z } from "zod"

const sentryId = z.union([z.string(), z.number()]).transform(String)

export const sentryPerson = z.object({
  id: sentryId,
  name: z.string().default(""),
  email: z.string().default("")
})

export const sentryOrganization = z.object({
  id: sentryId,
  slug: z.string(),
  name: z.string(),
  links: z.object({ regionUrl: z.string().nullish() }).nullish()
})

export const sentryTeam = z.object({ id: sentryId, slug: z.string(), name: z.string() })

export const sentryAssignee = z.object({
  type: z.enum(["user", "team"]),
  id: sentryId,
  name: z.string().default("")
})

export const sentryActivity = z.object({
  id: sentryId,
  type: z.string(),
  dateCreated: z.string(),
  user: sentryPerson.nullish(),
  data: z.record(z.string(), z.unknown()).default({})
})

export const sentryIssue = z.object({
  id: sentryId,
  shortId: z.string(),
  title: z.string(),
  culprit: z.string().nullish(),
  level: z.string().default("error"),
  status: z.string(),
  substatus: z.string().nullish(),
  permalink: z.string(),
  project: z.object({ id: sentryId, slug: z.string(), name: z.string() }),
  firstSeen: z.string(),
  lastSeen: z.string(),
  count: z.union([z.string(), z.number()]).transform(Number),
  userCount: z.number().default(0),
  assignedTo: sentryAssignee.nullish(),
  activity: z.array(sentryActivity).default([])
})

export type SentryPerson = z.infer<typeof sentryPerson>
export type SentryOrganization = z.infer<typeof sentryOrganization>
export type SentryTeam = z.infer<typeof sentryTeam>
export type SentryAssignee = z.infer<typeof sentryAssignee>
export type SentryActivity = z.infer<typeof sentryActivity>
export type SentryIssue = z.infer<typeof sentryIssue>
