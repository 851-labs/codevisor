import type { GmailApi, GmailLabel } from "./gmail-api.js"
import { findLabel, GmailToolError } from "./gmail-labels.js"
import {
  createLabelArguments,
  deleteLabelArguments,
  updateLabelArguments
} from "./gmail-tool-arguments.js"
import type { ToolRunner } from "./gmail-tool-runner.js"

export const listLabels: ToolRunner = async (_args, { api }) => ({
  labels: (await api.labels()).map(labelSummary)
})

export const createLabel: ToolRunner = async (args, { api }) => ({
  label: labelSummary(await api.createLabel(createLabelArguments.parse(args)))
})

export const updateLabel: ToolRunner = async (args, { api }) => {
  const { label, ...changes } = updateLabelArguments.parse(args)
  const existing = await userLabel(api, label)
  return { label: labelSummary(await api.updateLabel(existing.id, changes)) }
}

export const deleteLabel: ToolRunner = async (args, { api }) => {
  const existing = await userLabel(api, deleteLabelArguments.parse(args).label)
  await api.deleteLabel(existing.id)
  return { deleted: { id: existing.id, name: existing.name } }
}

const userLabel = async (api: GmailApi, wanted: string): Promise<GmailLabel> => {
  const label = findLabel(await api.labels(), wanted)
  if (label.type === "user") return label

  throw new GmailToolError(
    `${label.name} is a Gmail system label; only your own labels can change.`
  )
}

const labelSummary = (label: GmailLabel): Record<string, unknown> => ({
  id: label.id,
  name: label.name,
  type: label.type,
  ...definedFields({
    color: label.color,
    labelListVisibility: label.labelListVisibility,
    messageListVisibility: label.messageListVisibility
  })
})

const definedFields = (fields: Record<string, unknown>): Record<string, unknown> =>
  Object.fromEntries(Object.entries(fields).filter(([, value]) => value !== undefined))
