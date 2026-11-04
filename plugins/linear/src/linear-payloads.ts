import type { LinearComment, LinearIssue, LinearPerson, LinearViewer } from "./linear-api.js"

export const issuePayload = (issue: LinearIssue) => ({
  id: issue.id,
  identifier: issue.identifier,
  title: issue.title,
  url: issue.url,
  priority: issue.priority,
  priorityLabel: issue.priorityLabel,
  status: issue.state,
  team: issue.team,
  project: issue.project ?? null,
  assignee: personPayload(issue.assignee),
  creator: personPayload(issue.creator),
  labels: issue.labels.nodes.map((label) => label.name),
  createdAt: issue.createdAt,
  updatedAt: issue.updatedAt
})

export const commentPayload = (comment: LinearComment) => ({
  id: comment.id,
  body: clipped(comment.body),
  url: comment.url,
  createdAt: comment.createdAt
})

export const personPayload = (person: LinearPerson | null | undefined) =>
  person === null || person === undefined
    ? null
    : { id: person.id, name: person.name, email: person.email }

export const isViewer = (person: { id: string } | null | undefined, viewer: LinearViewer) =>
  person?.id === viewer.id

export const mentionsViewer = (text: string | null | undefined, viewer: LinearViewer): boolean =>
  profileLinkPattern(viewer.url).test(text ?? "")

export const issueChanges = (changedFields: ReadonlyArray<string>): Array<string> =>
  [...new Set(changedFields.flatMap((field) => changeNames[field] ?? []))].toSorted()

export const maxBodyChars = 4_000

const clipped = (text: string): string =>
  text.length > maxBodyChars ? `${text.slice(0, maxBodyChars)}…` : text

const profileLinkPattern = (profileUrl: string): RegExp =>
  new RegExp(`${escaped(profileUrl)}(?![\\w.-])`, "i")

const escaped = (text: string): string => text.replace(/[.*+?^${}()|[\]\\/]/g, "\\$&")

const changeNames: Readonly<Record<string, string>> = {
  stateId: "status",
  assigneeId: "assignee",
  priority: "priority",
  title: "title",
  description: "description",
  labelIds: "labels",
  projectId: "project",
  teamId: "team",
  cycleId: "cycle",
  dueDate: "dueDate",
  estimate: "estimate",
  parentId: "parent"
}
