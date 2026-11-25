import type { EventOccurrence } from "@codevisor/plugin-kit"

import type { SentryActivity, SentryIssue, SentryOrganization, SentryPerson } from "./sentry-api.js"
import { sentryEvents } from "./sentry-event-catalog.js"
import { commentPayload, issuePayload, occurrence, personPayload } from "./sentry-payloads.js"

export interface OrganizationView {
  organization: SentryOrganization
  me: SentryPerson
  teamIds: ReadonlySet<string>
}

export interface SentryAlert {
  kind: "issue" | "metric"
  rule: string
  status: string
  key: string
  timestamp: string
}

export const createdOccurrences = (
  view: OrganizationView,
  issue: SentryIssue
): Array<EventOccurrence> => [
  occurrence(sentryEvents.issueCreated, issue.id, issue.firstSeen, view.organization, {
    issue: issuePayload(issue)
  })
]

export const regressedOccurrences = (
  view: OrganizationView,
  issue: SentryIssue,
  since?: number
): Array<EventOccurrence> =>
  latestActivity(issue, "set_regression", since).map((activity) =>
    activityOccurrence(sentryEvents.issueRegressed, view, issue, activity, {
      release: textOrNull(activity.data.version)
    })
  )

export const escalatingOccurrences = (
  view: OrganizationView,
  issue: SentryIssue,
  since?: number
): Array<EventOccurrence> =>
  latestActivity(issue, "set_escalating", since).map((activity) =>
    activityOccurrence(sentryEvents.issueEscalating, view, issue, activity, {})
  )

export const assignedOccurrences = (
  view: OrganizationView,
  issue: SentryIssue,
  since?: number
): Array<EventOccurrence> =>
  latestActivity(issue, "assigned", since).flatMap((activity) => {
    const assignee = assigneeOf(activity, issue)
    const toMe = assignee.type === "user" && assignee.id === view.me.id
    const toMyTeam = assignee.type === "team" && view.teamIds.has(assignee.id)
    if (!toMe && !toMyTeam) return []

    return [
      activityOccurrence(sentryEvents.issueAssigned, view, issue, activity, {
        assignee,
        toMe,
        toMyTeam,
        byMe: activity.user?.id === view.me.id
      })
    ]
  })

export const commentOccurrences = (
  view: OrganizationView,
  issue: SentryIssue,
  commentId: string
): Array<EventOccurrence> =>
  issue.activity
    .filter((activity) => activity.type === "note" && activity.id === commentId)
    .map((note) =>
      activityOccurrence(sentryEvents.commentCreated, view, issue, note, {
        comment: commentPayload(note),
        author: personPayload(note.user),
        byMe: note.user?.id === view.me.id
      })
    )

export const alertOccurrences = (
  view: OrganizationView,
  alert: SentryAlert,
  issue: SentryIssue | undefined
): Array<EventOccurrence> => [
  occurrence(
    sentryEvents.alertFired,
    `${alert.kind}:${alert.key}`,
    alert.timestamp,
    view.organization,
    {
      alert: { kind: alert.kind, rule: alert.rule, status: alert.status },
      issue: issue === undefined ? null : issuePayload(issue)
    }
  )
]

const activityOccurrence = (
  name: string,
  view: OrganizationView,
  issue: SentryIssue,
  activity: SentryActivity,
  data: Record<string, unknown>
): EventOccurrence =>
  occurrence(name, activity.id, activity.dateCreated, view.organization, {
    issue: issuePayload(issue),
    ...data
  })

const latestActivity = (
  issue: SentryIssue,
  type: string,
  since: number | undefined
): Array<SentryActivity> => {
  const latest = issue.activity
    .filter((activity) => activity.type === type)
    .toSorted((left, right) => Date.parse(right.dateCreated) - Date.parse(left.dateCreated))[0]
  if (latest === undefined || tooOld(latest, since)) return []

  return [latest]
}

const tooOld = (activity: SentryActivity, since: number | undefined): boolean =>
  since !== undefined && Date.parse(activity.dateCreated) < since

const assigneeOf = (activity: SentryActivity, issue: SentryIssue) => {
  const type = activity.data.assigneeType === "team" ? "team" : "user"
  const id = textOrNull(activity.data.assignee) ?? ""
  const current = issue.assignedTo?.type === type && issue.assignedTo.id === id
  return {
    type,
    id,
    name: current ? (issue.assignedTo?.name ?? "") : (textOrNull(activity.data.assigneeEmail) ?? "")
  } as const
}

const textOrNull = (value: unknown): string | null => {
  if (typeof value === "number") return String(value)
  return typeof value === "string" && value !== "" ? value : null
}
