import { emptyArguments, type EventType } from "@codevisor/plugin-kit"

export const linearEvents = {
  issueCreated: "issue.created",
  issueUpdated: "issue.updated",
  commentCreated: "comment.created",
  mentionCreated: "mention.created"
} as const

export const linearIngress = { name: "linear", title: "Linear webhooks", route: "linear" }

const text = { type: "string" }
const flag = { type: "boolean" }
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

const person = record({ id: text, name: text, email: text })
const status = record({ id: text, name: text, type: text })

const issue = record({
  id: text,
  identifier: text,
  title: text,
  url: text,
  priority: { type: "integer" },
  priorityLabel: text,
  status,
  team: record({ id: text, key: text, name: text }),
  project: nullable(record({ id: text, name: text })),
  assignee: nullable(person),
  creator: nullable(person),
  labels: { type: "array", items: text },
  createdAt: time,
  updatedAt: time
})

const comment = record({ id: text, body: text, url: text, createdAt: time })

const issueChange = {
  type: "string",
  enum: [
    "status",
    "assignee",
    "priority",
    "title",
    "description",
    "labels",
    "project",
    "team",
    "cycle",
    "dueDate",
    "estimate",
    "parent"
  ]
}

const pushEvent = (
  name: string,
  title: string,
  description: string,
  payload: Record<string, unknown>
): EventType => ({
  name,
  title,
  description,
  delivery: ["push"],
  inputSchema: emptyArguments,
  payloadSchema: record(payload)
})

export const linearEventTypes: ReadonlyArray<EventType> = [
  pushEvent(
    linearEvents.issueCreated,
    "New issue",
    "An issue was created in a Linear team you can see. Filter on issue.team.key, issue.project.name, assignedToMe or byMe.",
    { issue, actor: nullable(person), byMe: flag, assignedToMe: flag }
  ),
  pushEvent(
    linearEvents.issueUpdated,
    "Issue changed",
    'An issue changed: its status, assignee, priority, title, labels, project and so on. `changes` lists what changed (for example "status" in changes) and `from` holds the previous status, assignee and priority.',
    {
      issue,
      changes: { type: "array", items: issueChange },
      from: record({
        status: nullable(status),
        assignee: nullable(person),
        priority: nullable({ type: "integer" })
      }),
      actor: nullable(person),
      byMe: flag,
      assignedToMe: flag
    }
  ),
  pushEvent(
    linearEvents.commentCreated,
    "New comment",
    "Someone commented on an issue. mentionsMe is true when the comment mentions you.",
    { comment, author: nullable(person), issue, byMe: flag, mentionsMe: flag, assignedToMe: flag }
  ),
  pushEvent(
    linearEvents.mentionCreated,
    "Mentioned",
    'Someone else mentioned you in a comment or in a new issue\'s description. source is "comment" or "issue"; comment is null for issues.',
    {
      source: { type: "string", enum: ["comment", "issue"] },
      issue,
      comment: nullable(comment),
      author: nullable(person)
    }
  )
]
