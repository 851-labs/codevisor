import { emptyArguments, type EventType } from "@codevisor/plugin-kit"

export const sentryEvents = {
  issueCreated: "issue.created",
  issueRegressed: "issue.regressed",
  issueEscalating: "issue.escalating",
  issueAssigned: "issue.assigned",
  commentCreated: "comment.created",
  alertFired: "alert.fired"
} as const

export type SentryEventName = (typeof sentryEvents)[keyof typeof sentryEvents]

export const sentryIngress = { name: "sentry", title: "Sentry webhooks", route: "sentry" }

const text = { type: "string" }
const flag = { type: "boolean" }
const count = { type: "integer" }
const time = { type: "string", format: "date-time" }

const record = (properties: Record<string, unknown>) => ({
  type: "object",
  properties,
  required: Object.keys(properties)
})

const nullable = (schema: { type: string } & Record<string, unknown>) => ({
  ...schema,
  type: [schema.type, "null"]
})

const organization = record({ id: text, slug: text, name: text })
const person = record({ id: text, name: text, email: text })
const assignee = record({ type: { type: "string", enum: ["user", "team"] }, id: text, name: text })

const issue = record({
  id: text,
  shortId: text,
  title: text,
  culprit: text,
  level: text,
  status: text,
  substatus: nullable(text),
  url: text,
  project: record({ id: text, slug: text, name: text }),
  firstSeen: time,
  lastSeen: time,
  count,
  userCount: count,
  assignee: nullable(assignee)
})

const sentryEvent = (
  name: SentryEventName,
  title: string,
  description: string,
  payload: Record<string, unknown>
): EventType => ({
  name,
  title,
  description,
  delivery: ["push"],
  inputSchema: emptyArguments,
  payloadSchema: record({ organization, ...payload })
})

const needsIntegration =
  "Arrives only from Sentry organizations that installed the Codevisor integration."

export const sentryEventTypes: ReadonlyArray<EventType> = [
  sentryEvent(
    sentryEvents.issueCreated,
    "New issue",
    "Sentry saw a new issue in an organization you belong to. Filter on organization.slug, issue.project.slug or issue.level.",
    { issue }
  ),
  sentryEvent(
    sentryEvents.issueRegressed,
    "Regression",
    "A resolved issue came back. release is the release it regressed in, or null.",
    { issue, release: nullable(text) }
  ),
  sentryEvent(
    sentryEvents.issueEscalating,
    "Escalating",
    "An issue is escalating: it's getting many more events than usual.",
    { issue }
  ),
  sentryEvent(
    sentryEvents.issueAssigned,
    "Assigned to me or my team",
    "An issue was assigned to you (toMe) or to one of your teams (toMyTeam). byMe is true when you assigned it.",
    { issue, assignee, toMe: flag, toMyTeam: flag, byMe: flag }
  ),
  sentryEvent(
    sentryEvents.commentCreated,
    "New comment",
    `Someone commented on an issue. byMe is true for your own comments. ${needsIntegration}`,
    {
      issue,
      comment: record({ id: text, text, createdAt: time }),
      author: nullable(person),
      byMe: flag
    }
  ),
  sentryEvent(
    sentryEvents.alertFired,
    "Alert fired",
    `An alert that uses "Send a notification via Codevisor" fired. alert.kind is "issue" or "metric"; issue is null for metric alerts. ${needsIntegration}`,
    {
      alert: record({
        kind: { type: "string", enum: ["issue", "metric"] },
        rule: text,
        status: text
      }),
      issue: nullable(issue)
    }
  )
]
