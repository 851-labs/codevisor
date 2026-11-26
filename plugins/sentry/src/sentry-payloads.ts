import type { EventOccurrence } from "@codevisor/plugin-kit"

import type {
  SentryActivity,
  SentryAssignee,
  SentryIssue,
  SentryOrganization,
  SentryPerson
} from "./sentry-api.js"

export const organizationPayload = (organization: SentryOrganization) => ({
  id: organization.id,
  slug: organization.slug,
  name: organization.name
})

export const issuePayload = (issue: SentryIssue) => ({
  id: issue.id,
  shortId: issue.shortId,
  title: issue.title,
  culprit: issue.culprit ?? "",
  level: issue.level,
  status: issue.status,
  substatus: issue.substatus ?? null,
  url: issue.permalink,
  project: issue.project,
  firstSeen: issue.firstSeen,
  lastSeen: issue.lastSeen,
  count: issue.count,
  userCount: issue.userCount,
  assignee: assigneePayload(issue.assignedTo)
})

export const assigneePayload = (assignee: SentryAssignee | null | undefined) =>
  assignee === null || assignee === undefined
    ? null
    : { type: assignee.type, id: assignee.id, name: assignee.name }

export const personPayload = (person: SentryPerson | null | undefined) =>
  person === null || person === undefined
    ? null
    : { id: person.id, name: person.name, email: person.email }

export const commentPayload = (note: SentryActivity) => ({
  id: note.id,
  text: clipped(typeof note.data.text === "string" ? note.data.text : ""),
  createdAt: note.dateCreated
})

export const occurrence = (
  name: string,
  key: string,
  timestamp: string,
  organization: SentryOrganization,
  data: Record<string, unknown>
): EventOccurrence => ({
  eventId: `${name}:${key}`,
  name,
  timestamp,
  data: { organization: organizationPayload(organization), ...data },
  cursor: null
})

export const maxCommentChars = 4_000

const clipped = (text: string): string =>
  text.length > maxCommentChars ? `${text.slice(0, maxCommentChars)}…` : text
