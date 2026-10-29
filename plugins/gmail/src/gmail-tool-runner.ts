import type { GmailApi } from "./gmail-api.js"

export interface ToolContext {
  api: GmailApi
  identity: string | undefined
}

export type ToolRunner = (
  args: Record<string, unknown>,
  context: ToolContext
) => Promise<Record<string, unknown>>
