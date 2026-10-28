import { withRunningThoughtLevel, type HarnessAccountContext } from "@codevisor/agent-runtime"
import type { CreateSessionRequest, Project } from "@codevisor/api"

import {
  HttpFailure,
  run,
  type CodevisorServerServices,
  type EventFanout
} from "../server-context.js"
import { sessionEventSink } from "./session-events.js"

export const resolveSessionAccount = async (
  services: CodevisorServerServices,
  payload: CreateSessionRequest
): Promise<{
  readonly accountContext: HarnessAccountContext | undefined
  readonly harnessAccountId: string | undefined
}> => {
  let accountContext: HarnessAccountContext | undefined
  if (payload.harnessAccountId === undefined) {
    accountContext = await services.auth?.activeAccountContext(payload.harnessId)
  } else {
    accountContext = await services.auth?.accountContext(payload.harnessAccountId)
  }
  /* v8 ignore next */
  if (
    services.auth !== undefined &&
    accountContext === undefined &&
    payload.deferAgentSession !== true
  ) {
    throw new HttpFailure(409, "Select a signed-in harness account before creating a session")
  }
  return { accountContext, harnessAccountId: payload.harnessAccountId ?? accountContext?.id }
}

export const withStartPicks = async (
  services: CodevisorServerServices,
  payload: CreateSessionRequest
): Promise<CreateSessionRequest> => {
  if (payload.configSelections !== undefined || payload.parentSessionId === undefined) {
    return payload
  }
  const parent = await run(services.db.getSessionSummary(payload.parentSessionId)).catch(
    () => undefined
  )
  if (parent === undefined || parent.harnessId !== payload.harnessId) return payload
  const unavailable = parent.unavailableConfigSelections ?? {}
  const inherited = Object.entries(parent.configSelections ?? {}).filter(
    ([configId, value]) => unavailable[configId] !== value
  )
  const runtime = await run(services.db.getSessionRuntimeState(parent.id))
  const picks = { ...withRunningThoughtLevel(undefined, runtime), ...Object.fromEntries(inherited) }
  return Object.keys(picks).length === 0 ? payload : { ...payload, configSelections: picks }
}

export const startSessionAgent = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  sessionId: string,
  project: Project,
  payload: CreateSessionRequest,
  cwd: string,
  accountContext: HarnessAccountContext | undefined
): Promise<string> => {
  const sink = sessionEventSink(services, fanout, serverId, sessionId)
  const toolGateway = await services.mcp?.issueGateway(sessionId, project.id, sink)
  if (payload.deferAgentSession === true) return ""
  return (
    payload.agentSessionId ??
    (await run(
      services.agents.createAgentSession(
        payload.harnessId,
        cwd,
        sink,
        accountContext,
        toolGateway,
        payload.configSelections === undefined
          ? undefined
          : { configSelections: payload.configSelections }
      )
    ))
  )
}
