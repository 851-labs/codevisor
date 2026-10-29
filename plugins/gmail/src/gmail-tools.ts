import { errorResult } from "@codevisor/plugin-kit"
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"
import { z } from "zod"

import { GmailApiError } from "./gmail-api.js"
import { GmailToolError } from "./gmail-labels.js"
import {
  listLabels,
  readMessage,
  readThread,
  searchMessages,
  searchThreads
} from "./gmail-read-tools.js"
import type { ToolContext, ToolRunner } from "./gmail-tool-runner.js"
import {
  archive,
  createDraft,
  markRead,
  markUnread,
  modifyLabels,
  reply,
  send,
  updateDraft
} from "./gmail-write-tools.js"

export const runGmailTool = async (
  name: string,
  args: Record<string, unknown>,
  context: ToolContext
): Promise<CallToolResult> => {
  const tool = toolRunners[name]
  if (tool === undefined) return errorResult(`Unknown tool: ${name}`)

  try {
    return compactResult(await tool(args, context))
  } catch (error) {
    return errorResult(failureMessage(error))
  }
}

const toolRunners: Readonly<Record<string, ToolRunner>> = {
  search_messages: searchMessages,
  search_threads: searchThreads,
  read_message: readMessage,
  read_thread: readThread,
  list_labels: listLabels,
  create_draft: createDraft,
  update_draft: updateDraft,
  send,
  reply,
  archive,
  modify_labels: modifyLabels,
  mark_read: markRead,
  mark_unread: markUnread
}

const compactResult = (value: Record<string, unknown>): CallToolResult => ({
  content: [{ type: "text", text: JSON.stringify(value) }],
  structuredContent: value
})

const failureMessage = (error: unknown): string => {
  if (error instanceof z.ZodError) return z.prettifyError(error)
  if (error instanceof GmailApiError || error instanceof GmailToolError) return error.message

  return `Gmail request failed: ${String(error)}`
}
