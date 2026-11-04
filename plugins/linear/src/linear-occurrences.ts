import type { EventOccurrence } from "@codevisor/plugin-kit"

import type { LinearApi, LinearComment, LinearIssue, LinearViewer } from "./linear-api.js"
import { linearEvents } from "./linear-event-catalog.js"
import {
  commentPayload,
  isViewer,
  issueChanges,
  issuePayload,
  mentionsViewer,
  personPayload
} from "./linear-payloads.js"
import type { LinearPing } from "./linear-ping.js"

export const occurrencesFor = (
  ping: LinearPing,
  api: LinearApi,
  viewer: LinearViewer
): Promise<Array<EventOccurrence>> => {
  const handler = handlers[`${ping.type}.${ping.action}`]
  if (handler === undefined) return Promise.resolve([])

  return handler(ping, api, viewer)
}

type PingHandler = (
  ping: LinearPing,
  api: LinearApi,
  viewer: LinearViewer
) => Promise<Array<EventOccurrence>>

const createdIssue: PingHandler = async (ping, api, viewer) => {
  const issue = await api.issue(ping.id)
  if (issue === null || issue === undefined) return []

  const created = occurrence(linearEvents.issueCreated, `issue:${issue.id}`, ping, {
    issue: issuePayload(issue),
    actor: personPayload(issue.creator),
    byMe: isViewer(issue.creator, viewer),
    assignedToMe: isViewer(issue.assignee, viewer)
  })
  if (!mentionedInIssue(issue, viewer)) return [created]

  return [created, issueMention(issue, ping)]
}

const updatedIssue: PingHandler = async (ping, api, viewer) => {
  const changes = issueChanges(ping.changed)
  if (changes.length === 0) return []

  const issue = await api.issue(ping.id)
  if (issue === null || issue === undefined) return []

  const context = await updateContext(ping, api)
  return [
    occurrence(
      linearEvents.issueUpdated,
      `issue:${issue.id}:${ping.updatedAt ?? ping.createdAt}`,
      ping,
      {
        issue: issuePayload(issue),
        changes,
        from: context.from,
        actor: personPayload(context.actor),
        byMe: ping.actorId === viewer.id,
        assignedToMe: isViewer(issue.assignee, viewer)
      }
    )
  ]
}

const createdComment: PingHandler = async (ping, api, viewer) => {
  const comment = await api.comment(ping.id)
  if (comment?.issue === null || comment?.issue === undefined) return []

  const mentionsMe = mentionsViewer(comment.body, viewer)
  const byMe = isViewer(comment.user, viewer)
  const created = occurrence(linearEvents.commentCreated, `comment:${comment.id}`, ping, {
    comment: commentPayload(comment),
    author: personPayload(comment.user),
    issue: issuePayload(comment.issue),
    byMe,
    mentionsMe,
    assignedToMe: isViewer(comment.issue.assignee, viewer)
  })
  if (!mentionsMe || byMe) return [created]

  return [created, commentMention(comment, comment.issue, ping)]
}

const handlers: Readonly<Record<string, PingHandler>> = {
  "Issue.create": createdIssue,
  "Issue.update": updatedIssue,
  "Comment.create": createdComment
}

const mentionedInIssue = (issue: LinearIssue, viewer: LinearViewer): boolean =>
  mentionsViewer(issue.description, viewer) && !isViewer(issue.creator, viewer)

const issueMention = (issue: LinearIssue, ping: LinearPing): EventOccurrence =>
  occurrence(linearEvents.mentionCreated, `issue:${issue.id}`, ping, {
    source: "issue",
    issue: issuePayload(issue),
    comment: null,
    author: personPayload(issue.creator)
  })

const commentMention = (
  comment: LinearComment,
  issue: LinearIssue,
  ping: LinearPing
): EventOccurrence =>
  occurrence(linearEvents.mentionCreated, `comment:${comment.id}`, ping, {
    source: "comment",
    issue: issuePayload(issue),
    comment: commentPayload(comment),
    author: personPayload(comment.user)
  })

const updateContext = async (ping: LinearPing, api: LinearApi) => {
  const [status, assignee, actor] = await Promise.all([
    lookUp(ping.previous.stateId, api.state),
    lookUp(ping.previous.assigneeId, api.user),
    lookUp(ping.actorId, api.user)
  ])
  return {
    from: { status, assignee: personPayload(assignee), priority: ping.previous.priority ?? null },
    actor
  }
}

const lookUp = async <T>(
  id: string | null | undefined,
  fetchOne: (id: string) => Promise<T | null | undefined>
): Promise<T | null> => {
  if (id === null || id === undefined) return null

  return (await fetchOne(id)) ?? null
}

const occurrence = (
  name: string,
  key: string,
  ping: LinearPing,
  data: Record<string, unknown>
): EventOccurrence => ({
  eventId: `${name}:${key}`,
  name,
  timestamp: ping.createdAt,
  data,
  cursor: null
})
