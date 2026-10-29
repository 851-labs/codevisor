import type { GmailApi, GmailDraft } from "./gmail-api.js"
import { composeMessage, type MessageFields } from "./gmail-compose.js"
import {
  newMessageFields,
  replyFields,
  updatedDraftFields,
  type NewMessage
} from "./gmail-composition.js"
import {
  archiveChange,
  GmailToolError,
  modifyTargets,
  readChange,
  resolveLabels,
  unreadChange
} from "./gmail-labels.js"
import {
  confirmationRequired,
  createDraftArguments,
  labelArguments,
  replyArguments,
  sendArguments,
  targetArguments,
  updateDraftArguments
} from "./gmail-tool-arguments.js"
import type { ToolContext, ToolRunner } from "./gmail-tool-runner.js"

export const createDraft: ToolRunner = async (args, context) => {
  const fields = await draftFields(createDraftArguments.parse(args), context)
  return draftResult(await context.api.createDraft(composeMessage(fields)), fields)
}

export const updateDraft: ToolRunner = async (args, { api }) => {
  const { draftId, ...changes } = updateDraftArguments.parse(args)
  const existing = await api.draft(draftId)
  const fields = updatedDraftFields(existing.message, changes)
  return draftResult(await api.updateDraft(draftId, composeMessage(fields)), fields)
}

export const send: ToolRunner = async (args, { api }) => {
  requireConfirmation("send", args)
  const input = sendArguments.parse(args)
  const sent = await sendMessage(api, input)
  return { messageId: sent.id, threadId: sent.threadId }
}

export const reply: ToolRunner = async (args, { api, identity }) => {
  requireConfirmation("reply", args)
  const { messageId, replyAll, ...input } = replyArguments.parse(args)
  const original = await api.message(messageId, "metadata")
  const fields = replyFields(original, input, { replyAll, identity })
  const sent = await api.send(composeMessage(fields))
  return { messageId: sent.id, threadId: sent.threadId, ...addressed(fields) }
}

export const archive: ToolRunner = async (args, { api }) =>
  modifyTargets(api, targetArguments.parse(args), archiveChange)

export const markRead: ToolRunner = async (args, { api }) =>
  modifyTargets(api, targetArguments.parse(args), readChange)

export const markUnread: ToolRunner = async (args, { api }) =>
  modifyTargets(api, targetArguments.parse(args), unreadChange)

export const modifyLabels: ToolRunner = async (args, { api }) => {
  const { add, remove, ...targets } = labelArguments.parse(args)
  return modifyTargets(api, targets, await resolveLabels(api, { add, remove }))
}

interface DraftRequest extends NewMessage {
  inReplyToMessageId?: string | undefined
  replyAll: boolean
}

const draftFields = async (
  { inReplyToMessageId, replyAll, ...input }: DraftRequest,
  { api, identity }: ToolContext
): Promise<MessageFields> => {
  if (inReplyToMessageId === undefined) return newMessageFields(input)

  const original = await api.message(inReplyToMessageId, "metadata")
  return replyFields(original, input, { replyAll, identity })
}

const sendMessage = (api: GmailApi, input: { draftId: string } | NewMessage) => {
  if ("draftId" in input) return api.sendDraft(input.draftId)

  return api.send(composeMessage(newMessageFields(input)))
}

const requireConfirmation = (tool: string, args: Record<string, unknown>): void => {
  if (args.confirm !== true) throw new GmailToolError(confirmationRequired(tool))
}

const draftResult = (draft: GmailDraft, fields: MessageFields): Record<string, unknown> => ({
  draftId: draft.id,
  messageId: draft.message.id,
  threadId: draft.message.threadId,
  ...addressed(fields)
})

const addressed = (fields: MessageFields): Record<string, string> =>
  Object.fromEntries(
    Object.entries({
      to: fields.to,
      cc: fields.cc,
      bcc: fields.bcc,
      subject: fields.subject
    }).filter(([, value]) => value !== "")
  )
