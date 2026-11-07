import type { GmailApi, GmailLabel, LabelChange } from "./gmail-api.js"

export interface Targets {
  messageIds: ReadonlyArray<string>
  threadIds: ReadonlyArray<string>
}

export interface Modified {
  [key: string]: unknown
  messages: number
  threads: number
}

export class GmailToolError extends Error {}

export const archiveChange: LabelChange = { add: [], remove: ["INBOX"] }
export const readChange: LabelChange = { add: [], remove: ["UNREAD"] }
export const unreadChange: LabelChange = { add: ["UNREAD"], remove: [] }

export const findLabel = (labels: ReadonlyArray<GmailLabel>, wanted: string): GmailLabel => {
  const found =
    labels.find((label) => label.id === wanted) ??
    labels.find((label) => label.name.toLowerCase() === wanted.toLowerCase())
  if (found !== undefined) return found

  throw new GmailToolError(
    `Unknown label "${wanted}". Call list_labels to see the label names, or create_label to add it.`
  )
}

export const resolveLabels = async (api: GmailApi, change: LabelChange): Promise<LabelChange> => {
  const labels = await api.labels()
  return {
    add: change.add.map((label) => findLabel(labels, label).id),
    remove: change.remove.map((label) => findLabel(labels, label).id)
  }
}

export const modifyTargets = async (
  api: GmailApi,
  targets: Targets,
  change: LabelChange
): Promise<Modified> => {
  if (targets.messageIds.length > 0) await api.modifyMessages(targets.messageIds, change)
  await Promise.all(targets.threadIds.map((id) => api.modifyThread(id, change)))
  return { messages: targets.messageIds.length, threads: targets.threadIds.length }
}
