import { isExternalClientKey, parseRemoteSessionKey } from "@codevisor/api"

import type { AgentToolContext } from "./codevisor-agent-tool.js"

export const isRemoteScope = (sessionId: string): boolean =>
  parseRemoteSessionKey(sessionId) !== undefined

export const hasNoLocalChat = (sessionId: string): boolean =>
  isRemoteScope(sessionId) || isExternalClientKey(sessionId)

export const localCallerId = (tool: AgentToolContext, action: string): string => {
  if (isRemoteScope(tool.context.sessionId))
    throw new Error(`${action} only works for agents on your own machine`)
  if (isExternalClientKey(tool.context.sessionId))
    throw new Error(
      `${action} acts for a Codevisor chat, and you're connected from outside Codevisor. Follow agents with agents.wait and agents.status instead`
    )
  return tool.context.sessionId
}
