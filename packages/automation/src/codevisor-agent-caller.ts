import { parseRemoteSessionKey, SessionSummary } from "@codevisor/api"
import { Schema } from "effect"

import type { AgentToolContext } from "./codevisor-agent-tool.js"

export const isRemoteScope = (sessionId: string): boolean =>
  parseRemoteSessionKey(sessionId) !== undefined

export const agentSummary = async (
  tool: AgentToolContext,
  agentId: string
): Promise<SessionSummary> =>
  decodeDetail(await tool.api("GET", `/v1/sessions/${encodeURIComponent(agentId)}`)).session

export const localCallerId = (tool: AgentToolContext, action: string): string => {
  if (isRemoteScope(tool.context.sessionId))
    throw new Error(`${action} works on your own machine only: call it on machines.current`)
  return tool.context.sessionId
}

const decodeDetail = Schema.decodeUnknownSync(Schema.Struct({ session: SessionSummary }))
