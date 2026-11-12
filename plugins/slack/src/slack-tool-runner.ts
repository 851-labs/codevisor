import type { SlackApi } from "./slack-api.js"
import type { SlackDirectory } from "./slack-directory.js"
import type { SlackFiles } from "./slack-files.js"

export interface ToolContext {
  api: SlackApi
  directory: SlackDirectory
  files: SlackFiles
}

export type ToolRunner = (
  args: Record<string, unknown>,
  context: ToolContext
) => Promise<Record<string, unknown>>
