import { parseRemoteSessionKey } from "@codevisor/api"

import type { AgentToolContext } from "./codevisor-agent-tool.js"

export const isRemoteScope = (sessionId: string): boolean =>
  parseRemoteSessionKey(sessionId) !== undefined

export const localCallerId = (tool: AgentToolContext, action: string): string => {
  if (isRemoteScope(tool.context.sessionId))
    throw new Error(`${action} only works for agents on your own machine`)
  return tool.context.sessionId
}
