import type { EventOccurrence } from "@codevisor/plugin-kit"

import type { IssueSearch, SentryApi, SentryIssue } from "./sentry-api.js"
import { sentryEvents } from "./sentry-event-catalog.js"
import {
  assignedOccurrences,
  createdOccurrences,
  escalatingOccurrences,
  type OrganizationView,
  regressedOccurrences
} from "./sentry-occurrences.js"

export interface PollState {
  watermark: number
  seen: Map<string, Map<string, string>>
}

export const pollIntervalMs = 30_000
export const pollOverlapMs = 2 * 60_000

export const polledEvents: ReadonlySet<string> = new Set([
  sentryEvents.issueCreated,
  sentryEvents.issueRegressed,
  sentryEvents.issueEscalating,
  sentryEvents.issueAssigned
])

export const pollOrganization = async (
  api: SentryApi,
  view: OrganizationView,
  eventName: string,
  state: PollState
): Promise<Array<EventOccurrence>> => {
  const poller = pollers[eventName]
  if (poller === undefined) return []

  const since = state.watermark - pollOverlapMs
  const issues = await api.issues(view.organization, poller.search(since))
  if (poller.signature === undefined)
    return issues.flatMap((issue) => poller.occurrences(view, issue, since))

  const changed = changedIssues(state, `${eventName}:${view.organization.id}`, issues, poller)
  const details = await Promise.all(changed.map((issue) => api.issue(view.organization, issue.id)))
  return details.flatMap((issue) =>
    issue === undefined ? [] : poller.occurrences(view, issue, since)
  )
}

interface IssuePoller {
  search(since: number): IssueSearch
  signature?: (issue: SentryIssue) => string
  occurrences(view: OrganizationView, issue: SentryIssue, since: number): Array<EventOccurrence>
}

const changedIssues = (
  state: PollState,
  key: string,
  issues: ReadonlyArray<SentryIssue>,
  poller: IssuePoller
): ReadonlyArray<SentryIssue> => {
  const previous = state.seen.get(key)
  const current = new Map(issues.map((issue) => [issue.id, poller.signature?.(issue) ?? ""]))
  state.seen.set(key, current)
  if (previous === undefined) return []

  return issues.filter((issue) => previous.get(issue.id) !== current.get(issue.id))
}

export const sentryTime = (milliseconds: number): string =>
  new Date(milliseconds).toISOString().slice(0, "YYYY-MM-DDTHH:MM:SS".length)

const recentlySeen = (substatus: string) => (since: number) => ({
  query: `is:${substatus} lastSeen:>${sentryTime(since)}`,
  sort: "date" as const,
  limit: changedIssueLimit
})

const changedIssueLimit = 25
const assignedIssueLimit = 100

const pollers: Readonly<Record<string, IssuePoller>> = {
  [sentryEvents.issueCreated]: {
    search: (since) => ({
      query: `firstSeen:>${sentryTime(since)}`,
      sort: "new",
      limit: changedIssueLimit
    }),
    occurrences: (view, issue) => createdOccurrences(view, issue)
  },
  [sentryEvents.issueRegressed]: {
    search: recentlySeen("regressed"),
    signature: () => "regressed",
    occurrences: regressedOccurrences
  },
  [sentryEvents.issueEscalating]: {
    search: recentlySeen("escalating"),
    signature: () => "escalating",
    occurrences: escalatingOccurrences
  },
  [sentryEvents.issueAssigned]: {
    search: () => ({
      query: "assigned:[me, my_teams] is:unresolved",
      sort: "date",
      limit: assignedIssueLimit
    }),
    signature: (issue) => `${issue.assignedTo?.type ?? ""}:${issue.assignedTo?.id ?? ""}`,
    occurrences: assignedOccurrences
  }
}
