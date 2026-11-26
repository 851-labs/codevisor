import type { EventOccurrence } from "@codevisor/plugin-kit"

import type { SentryApi, SentryIssue } from "./sentry-api.js"
import {
  alertOccurrences,
  assignedOccurrences,
  commentOccurrences,
  createdOccurrences,
  escalatingOccurrences,
  type OrganizationView,
  regressedOccurrences
} from "./sentry-occurrences.js"
import type { SentryPing } from "./sentry-ping.js"

export const webhookOccurrences = async (
  ping: SentryPing,
  api: SentryApi,
  view: OrganizationView
): Promise<Array<EventOccurrence>> => {
  const handler = handlers[ping.resource]
  const issue = await issueOf(ping, api, view)
  return handler(ping, view, issue)
}

type PingHandler = (
  ping: SentryPing,
  view: OrganizationView,
  issue: SentryIssue | undefined
) => Array<EventOccurrence>

const issueChanged: PingHandler = (ping, view, issue) => {
  if (issue === undefined) return []

  return issueHandlers[issueChange(ping)]?.(view, issue) ?? []
}

const commented: PingHandler = (ping, view, issue) => {
  if (issue === undefined || ping.commentId === undefined) return []

  return commentOccurrences(view, issue, ping.commentId)
}

const issueAlerted: PingHandler = (ping, view, issue) => {
  if (ping.alert === undefined || issue === undefined) return []

  const key = `${ping.eventId ?? issue.id}:${ping.alert.rule}`
  return alertOccurrences(
    view,
    { kind: "issue", ...ping.alert, key, timestamp: ping.timestamp },
    issue
  )
}

const metricAlerted: PingHandler = (ping, view) => {
  if (ping.alert === undefined) return []

  const key = `${ping.alert.incidentId ?? ping.alert.rule}:${ping.alert.status}`
  return alertOccurrences(
    view,
    { kind: "metric", ...ping.alert, key, timestamp: ping.timestamp },
    undefined
  )
}

const handlers: Readonly<Record<SentryPing["resource"], PingHandler>> = {
  issue: issueChanged,
  comment: commented,
  event_alert: issueAlerted,
  metric_alert: metricAlerted
}

const issueHandlers: Readonly<
  Record<string, (view: OrganizationView, issue: SentryIssue) => Array<EventOccurrence>>
> = {
  created: createdOccurrences,
  assigned: (view, issue) => assignedOccurrences(view, issue),
  "unresolved:regressed": (view, issue) => regressedOccurrences(view, issue),
  "unresolved:escalating": (view, issue) => escalatingOccurrences(view, issue)
}

const issueChange = (ping: SentryPing): string =>
  ping.action === "unresolved" ? `${ping.action}:${ping.substatus ?? ""}` : ping.action

const issueOf = async (
  ping: SentryPing,
  api: SentryApi,
  view: OrganizationView
): Promise<SentryIssue | undefined> => {
  if (ping.issueId === undefined) return undefined

  return api.issue(view.organization, ping.issueId)
}
