import type { HarnessAccountContext } from "@codevisor/agent-runtime"
import type { CreateSessionRequest, Project } from "@codevisor/api"

import {
  HttpFailure,
  run,
  type CodevisorServerServices,
  type EventFanout
} from "../server-context.js"
import { sessionEventSink } from "./session-events.js"

/// The parts of creating a session that live OUTSIDE the database — account
/// gating and the provider session — shared by the discrete POST /v1/sessions
/// and the atomic workspace create so both bind sessions identically.

/// The harness account a new session binds to, gated exactly like the
/// discrete create: an agent that starts now needs a signed-in account.
export const resolveSessionAccount = async (
  services: CodevisorServerServices,
  payload: CreateSessionRequest
): Promise<{
  readonly accountContext: HarnessAccountContext | undefined
  readonly harnessAccountId: string | undefined
}> => {
  const accountContext =
    payload.harnessAccountId === undefined
      ? await services.auth?.activeAccountContext(payload.harnessId)
      : await services.auth?.accountContext(payload.harnessAccountId)
  /* v8 ignore next -- both accepted and rejected auth-gating paths are integration-tested. */
  if (
    services.auth !== undefined &&
    accountContext === undefined &&
    payload.deferAgentSession !== true
  ) {
    throw new HttpFailure(409, "Select a signed-in harness account before creating a session")
  }
  return { accountContext, harnessAccountId: payload.harnessAccountId ?? accountContext?.id }
}

/// The picks a new chat starts with: its own, else its parent's when both
/// run the same harness, so a chat an agent creates runs (and its picker
/// shows) the model the agent itself runs. Parent picks its runtime no
/// longer offers stay behind: the parent is not running them.
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
  return inherited.length === 0
    ? payload
    : { ...payload, configSelections: Object.fromEntries(inherited) }
}

/// Starts (or adopts) the provider session behind a Codevisor session row.
/// The session id is known up front so the standing event sink can bind to
/// it before the agent session exists. Deferred agents start on first use.
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
  return payload.deferAgentSession === true
    ? ""
    : (payload.agentSessionId ??
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
        )))
}
