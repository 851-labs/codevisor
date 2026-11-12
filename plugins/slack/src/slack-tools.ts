import { errorResult } from "@codevisor/plugin-kit"
import type { CallToolResult } from "@modelcontextprotocol/server"
import { z } from "zod"

import { SlackApiError } from "./slack-api.js"
import { SlackToolError } from "./slack-directory.js"
import { downloadFile, uploadFile } from "./slack-file-tools.js"
import {
  findUsers,
  getUser,
  listChannelMembers,
  listChannels,
  readChannel,
  readThread,
  searchFiles,
  searchMessages
} from "./slack-read-tools.js"
import type { ToolContext, ToolRunner } from "./slack-tool-runner.js"
import { addReaction, postMessage, removeReaction, scheduleMessage } from "./slack-write-tools.js"

export const runSlackTool = async (
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
  search_files: searchFiles,
  list_channels: listChannels,
  find_users: findUsers,
  get_user: getUser,
  read_channel: readChannel,
  read_thread: readThread,
  list_channel_members: listChannelMembers,
  download_file: downloadFile,
  add_reaction: addReaction,
  remove_reaction: removeReaction,
  post_message: postMessage,
  schedule_message: scheduleMessage,
  upload_file: uploadFile
}

const compactResult = (value: Record<string, unknown>): CallToolResult => ({
  content: [{ type: "text", text: JSON.stringify(value) }],
  structuredContent: value
})

const failureMessage = (error: unknown): string => {
  if (error instanceof z.ZodError) return z.prettifyError(error)
  if (error instanceof SlackApiError || error instanceof SlackToolError) return error.message

  return `Slack request failed: ${error instanceof Error ? error.message : String(error)}`
}
