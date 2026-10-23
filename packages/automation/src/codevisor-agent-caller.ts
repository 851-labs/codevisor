import { SessionSummary } from "@codevisor/api"
import { Schema } from "effect"

import type { CallerDefaults } from "./codevisor-agent-start.js"
import type { AgentToolContext } from "./codevisor-agent-tool.js"

export interface AgentCaller {
  readonly sessionId?: string
  readonly projectId?: string
  readonly workspaceId?: string
  readonly worktreeName?: string
  readonly harnessId?: string
  readonly configSelections?: Readonly<Record<string, string>>
}

export const isRemoteCaller = (tool: AgentToolContext): boolean =>
  tool.context.sessionId.startsWith(remoteScopePrefix)

export const callerSession = async (
  tool: AgentToolContext,
  defaults: CallerDefaults | undefined
): Promise<AgentCaller> => {
  if (isRemoteCaller(tool)) return remoteCaller(defaults)
  return localCaller(await agentSummary(tool, tool.context.sessionId))
}

export const agentSummary = async (
  tool: AgentToolContext,
  agentId: string
): Promise<SessionSummary> =>
  decodeDetail(await tool.api("GET", `/v1/sessions/${encodeURIComponent(agentId)}`)).session

export const localCallerId = (tool: AgentToolContext, action: string): string => {
  if (isRemoteCaller(tool))
    throw new Error(`${action} works on your own machine only: call it on machines.current`)
  return tool.context.sessionId
}

const remoteScopePrefix = "remote:"

const decodeDetail = Schema.decodeUnknownSync(Schema.Struct({ session: SessionSummary }))

const remoteCaller = (defaults: CallerDefaults | undefined): AgentCaller => ({
  ...(defaults === undefined ? {} : { harnessId: defaults.harness }),
  ...(defaults?.configSelections === undefined
    ? {}
    : { configSelections: defaults.configSelections })
})

const localCaller = (session: SessionSummary): AgentCaller => ({
  sessionId: session.id,
  projectId: session.projectId,
  harnessId: session.harnessId,
  ...(session.workspaceId === undefined ? {} : { workspaceId: session.workspaceId }),
  ...(session.worktreeName === undefined ? {} : { worktreeName: session.worktreeName }),
  ...(session.configSelections === undefined ? {} : { configSelections: session.configSelections })
})
