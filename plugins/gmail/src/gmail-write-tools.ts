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
import { fromHeader, replySendAs, requestedFrom, sendAsAddresses } from "./gmail-send-as.js"
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
  const { draftId, from, ...changes } = updateDraftArguments.parse(args)
  const existing = await api.draft(draftId)
  const sender = await requestedFrom(api, from)
  const fields = updatedDraftFields(existing.message, { ...changes, from: sender })
  return draftResult(await api.updateDraft(draftId, composeMessage(fields)), fields)
}

export const send: ToolRunner = async (args, { api }) => {
  requireConfirmation("send", args)
  const input = sendArguments.parse(args)
  const sent = await sendMessage(api, input)
  return { messageId: sent.id, threadId: sent.threadId }
}

export const reply: ToolRunner = async (args, context) => {
  requireConfirmation("reply", args)
  const fields = await replyFieldsFor(replyArguments.parse(args), context)
  const sent = await context.api.send(composeMessage(fields))
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

interface NewMessageRequest extends NewMessage {
  from?: string | undefined
}

interface DraftRequest extends NewMessageRequest {
  inReplyToMessageId?: string | undefined
  replyAll: boolean
}

interface ReplyRequest extends NewMessageRequest {
  messageId: string
  replyAll: boolean
}

const draftFields = async (
  { inReplyToMessageId, ...input }: DraftRequest,
  context: ToolContext
): Promise<MessageFields> => {
  if (inReplyToMessageId === undefined) return newFieldsFor(context.api, input)

  return replyFieldsFor({ ...input, messageId: inReplyToMessageId }, context)
}

const newFieldsFor = async (
  api: GmailApi,
  { from, ...input }: NewMessageRequest
): Promise<MessageFields> => newMessageFields(input, await requestedFrom(api, from))

const replyFieldsFor = async (
  { messageId, replyAll, from, ...input }: ReplyRequest,
  { api }: ToolContext
): Promise<MessageFields> => {
  const [original, addresses] = await Promise.all([
    api.message(messageId, "metadata"),
    sendAsAddresses(api)
  ])
  const sender = replySendAs(addresses, original, from)
  return replyFields(original, input, {
    replyAll,
    me: addresses.map((address) => address.email),
    from: fromHeader(addresses, sender)
  })
}

const sendMessage = async (api: GmailApi, input: { draftId: string } | NewMessageRequest) => {
  if ("draftId" in input) return api.sendDraft(input.draftId)

  return api.send(composeMessage(await newFieldsFor(api, input)))
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
      from: fields.from,
      to: fields.to,
      cc: fields.cc,
      bcc: fields.bcc,
      subject: fields.subject
    }).filter(([, value]) => value !== "")
  )
