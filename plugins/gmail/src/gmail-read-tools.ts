import { messageDetail, messageSummary, threadSummary } from "./gmail-message.js"
import { sendAsAddresses, type SendAsAddress } from "./gmail-send-as.js"
import { messageArguments, searchArguments, threadArguments } from "./gmail-tool-arguments.js"
import type { ToolRunner } from "./gmail-tool-runner.js"

export const searchMessages: ToolRunner = async (args, { api }) => {
  const { query, maxResults, pageToken } = searchArguments.parse(args)
  const found = await api.listMessages({ query, maxResults, pageToken })
  const messages = await Promise.all(found.messages.map((ref) => api.message(ref.id, "metadata")))
  return { messages: messages.map(messageSummary), ...nextPage(found.nextPageToken) }
}

export const searchThreads: ToolRunner = async (args, { api }) => {
  const { query, maxResults, pageToken } = searchArguments.parse(args)
  const found = await api.listThreads({ query, maxResults, pageToken })
  const threads = await Promise.all(found.threads.map((ref) => api.thread(ref.id, "metadata")))
  return { threads: threads.map(threadSummary), ...nextPage(found.nextPageToken) }
}

export const readMessage: ToolRunner = async (args, { api }) => {
  const { messageId } = messageArguments.parse(args)
  return messageDetail(await api.message(messageId, "full"), "whole")
}

export const readThread: ToolRunner = async (args, { api }) => {
  const { threadId } = threadArguments.parse(args)
  const thread = await api.thread(threadId, "full")
  return {
    threadId: thread.id,
    messages: thread.messages.map((message) => messageDetail(message, "latest"))
  }
}

export const listSendAs: ToolRunner = async (_args, { api }) => ({
  addresses: (await sendAsAddresses(api)).map(sendAsSummary)
})

const sendAsSummary = (address: SendAsAddress): Record<string, unknown> => ({
  email: address.email,
  ...(address.name === "" ? {} : { name: address.name }),
  default: address.isDefault
})

const nextPage = (token: string | undefined): { nextPageToken?: string } =>
  token === undefined ? {} : { nextPageToken: token }
