import { z } from "zod"

import { maxSearchResults } from "./gmail-tool-catalog.js"

export const confirmationRequired = (tool: string): string =>
  `${tool} requires confirm: true. Show the user the exact recipients, subject and body, and get their explicit approval first.`

const id = z.string().min(1)
const ids = z.array(id).default([])
const optionalText = z.string().optional()

const recipients = {
  to: optionalText,
  cc: optionalText,
  bcc: optionalText,
  subject: optionalText
}

const hasTarget = (value: { messageIds: Array<string>; threadIds: Array<string> }): boolean =>
  value.messageIds.length + value.threadIds.length > 0

const targetShape = { messageIds: ids, threadIds: ids }

export const searchArguments = z.object({
  query: z.string(),
  maxResults: z.number().int().min(1).max(maxSearchResults).default(10),
  pageToken: id.optional()
})

export const messageArguments = z.object({ messageId: id })

export const threadArguments = z.object({ threadId: id })

export const createDraftArguments = z.object({
  ...recipients,
  body: z.string(),
  inReplyToMessageId: id.optional(),
  replyAll: z.boolean().default(false)
})

export const updateDraftArguments = z.object({
  draftId: id,
  ...recipients,
  body: optionalText
})

export const sendArguments = z.union([
  z.object({ draftId: id }),
  z.object({ ...recipients, to: z.string().min(1), subject: z.string(), body: z.string() })
])

export const replyArguments = z.object({
  messageId: id,
  body: z.string(),
  replyAll: z.boolean().default(false),
  cc: optionalText
})

export const targetArguments = z
  .object(targetShape)
  .refine(hasTarget, "Give at least one message id or thread id.")

export const labelArguments = z
  .object({ ...targetShape, add: ids, remove: ids })
  .refine(hasTarget, "Give at least one message id or thread id.")
  .refine(
    (value) => value.add.length + value.remove.length > 0,
    "Give at least one label to add or remove."
  )
