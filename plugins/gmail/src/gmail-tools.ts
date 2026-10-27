import { errorResult, structuredResult } from "@codevisor/plugin-kit"
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"
import { z } from "zod"

import { type GmailApi, GmailApiError } from "./gmail-api.js"
import { composeMessage } from "./gmail-compose.js"
import { messageDetail, messageSummary } from "./gmail-message.js"

export const runGmailTool = async (
  name: string,
  args: Record<string, unknown>,
  api: GmailApi
): Promise<CallToolResult> => {
  const tool = toolRunners[name]
  if (tool === undefined) return errorResult(`Unknown tool: ${name}`)

  try {
    return structuredResult(await tool(args, api))
  } catch (error) {
    return errorResult(failureMessage(error))
  }
}

type ToolRunner = (args: Record<string, unknown>, api: GmailApi) => Promise<Record<string, unknown>>

const search: ToolRunner = async (args, api) => {
  const { query, maxResults } = searchArguments.parse(args)
  const found = await api.listMessages(query, maxResults)
  const messages = await Promise.all(found.map((ref) => api.message(ref.id, "metadata")))
  return { messages: messages.map(messageSummary) }
}

const readMessage: ToolRunner = async (args, api) => {
  const { messageId } = messageArguments.parse(args)
  return { message: messageDetail(await api.message(messageId, "full")) }
}

const readThread: ToolRunner = async (args, api) => {
  const { threadId } = threadArguments.parse(args)
  const thread = await api.thread(threadId)
  return { threadId: thread.id, messages: thread.messages.map(messageDetail) }
}

const createDraft: ToolRunner = async (args, api) => {
  const outgoing = await composeMessage(api, draftArguments.parse(args))
  const draft = await api.createDraft(outgoing.raw, outgoing.threadId)
  return { draftId: draft.id, messageId: draft.message.id, threadId: draft.message.threadId }
}

const send: ToolRunner = async (args, api) => {
  const outgoing = await composeMessage(api, sendArguments.parse(args))
  const sent = await api.send(outgoing.raw, outgoing.threadId)
  return { messageId: sent.id, threadId: sent.threadId, labels: sent.labelIds }
}

const modifyLabels: ToolRunner = async (args, api) => {
  const { messageId, add, remove } = labelArguments.parse(args)
  const message = await api.modifyLabels(messageId, add, remove)
  return { messageId: message.id, labels: message.labelIds }
}

const toolRunners: Record<string, ToolRunner> = {
  search,
  read_message: readMessage,
  read_thread: readThread,
  create_draft: createDraft,
  send,
  modify_labels: modifyLabels
}

const failureMessage = (error: unknown): string => {
  if (error instanceof z.ZodError) return z.prettifyError(error)
  if (error instanceof GmailApiError) return error.message

  return `Gmail request failed: ${String(error)}`
}

const id = z.string().min(1)
const labelIds = z.array(z.string().min(1)).default([])

const searchArguments = z.object({
  query: z.string(),
  maxResults: z.number().int().min(1).max(50).default(10)
})
const messageArguments = z.object({ messageId: id })
const threadArguments = z.object({ threadId: id })

const replyArguments = {
  subject: z.string().optional(),
  body: z.string(),
  threadId: id.optional(),
  inReplyToMessageId: id.optional()
}

const draftArguments = z.object({ to: z.string().optional(), ...replyArguments })
const sendArguments = z.object({
  to: z.string().min(1),
  cc: z.string().optional(),
  ...replyArguments,
  subject: z.string()
})

const labelArguments = z
  .object({ messageId: id, add: labelIds, remove: labelIds })
  .refine(
    (value) => value.add.length + value.remove.length > 0,
    "Give at least one label id to add or remove."
  )
