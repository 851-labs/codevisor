import type { IncomingMessage, ServerResponse } from "node:http"

import type { HarnessAccount, HarnessUsageLimits, Project, SessionSummary } from "@codevisor/api"
import {
  MarkSessionReadRequest as MarkSessionReadRequestSchema,
  CreateSessionRequest as CreateSessionRequestSchema,
  UpdateSessionRequest as UpdateSessionRequestSchema,
  WaitForSessionsRequest as WaitForSessionsRequestSchema
} from "@codevisor/api"
import { gitBranchDiffTotals } from "@codevisor/worktrees"

import {
  appendAndPublish,
  getProjectOrFail,
  HttpFailure,
  matchRoute,
  readSchema,
  run,
  writeJson
} from "../server-context.js"
import type {
  CodevisorServerConfig,
  CodevisorServerServices,
  EventFanout,
  RouteState
} from "../server-context.js"
import { withAutoResume } from "./auto-resume-routes.js"
import { assertNotOwnedByBot } from "./bot-guards.js"
import { matchesLabelFilters } from "./label-filters.js"
import { rejectSyncThrows } from "./route-context.js"
import type { RouteContext } from "./route-context.js"
import { routeSessionActions } from "./session-actions.js"
import { readSessionUsageLimits } from "./session-usage-limits.js"
import { waitForSessions } from "./session-wait.js"
import {
  applySessionUpdate,
  createSessionIfMissing,
  findSession,
  resolveSessionCwdOrFail
} from "./session-workspace.js"
import { withUpdateGate } from "./update-gate.js"

export { reconcileOrphanedSessionTurns } from "./prompt-recovery.js"

export {
  drainPromptQueue,
  makeTurnDispatchListener,
  reconcileStaleStreamingTurns
} from "./prompt-queue.js"

export const MAX_PROMPT_ATTACHMENTS = 10

export const routeSessions = (
  services: CodevisorServerServices,
  fanout: EventFanout,
  routeState: RouteState,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL,
  config: CodevisorServerConfig
): Promise<boolean> =>
  rejectSyncThrows(() =>
    dispatchSessionRoute({ services, fanout, routeState, request, response, url, config })
  )

const dispatchSessionRoute = (route: RouteContext): Promise<boolean> => {
  const { request, url } = route
  if (request.method === "GET" && url.pathname === "/v1/sessions") return listSessions(route)
  if (request.method === "POST" && url.pathname === "/v1/sessions/wait") return awaitSessions(route)
  if (request.method === "POST" && url.pathname === "/v1/sessions") return createSession(route)

  const branchDiffSessionId = matchRoute(url.pathname, "/v1/sessions/:id/branch-diff")
  if (branchDiffSessionId !== undefined && request.method === "GET")
    return readBranchDiff(route, branchDiffSessionId)

  const usageLimitsSessionId = matchRoute(url.pathname, "/v1/sessions/:id/usage-limits")
  if (usageLimitsSessionId !== undefined && request.method === "GET")
    return readUsageLimits(route, usageLimitsSessionId)

  const contextSessionId = matchRoute(url.pathname, "/v1/sessions/:id/context")
  if (contextSessionId !== undefined && request.method === "GET")
    return readSessionContext(route, contextSessionId)

  const readSessionId = matchRoute(url.pathname, "/v1/sessions/:id/read")
  if (readSessionId !== undefined && request.method === "POST")
    return markRead(route, readSessionId)

  const unreadSessionId = matchRoute(url.pathname, "/v1/sessions/:id/unread")
  if (unreadSessionId !== undefined && request.method === "POST")
    return markUnread(route, unreadSessionId)

  const planApprovalSessionId = matchRoute(url.pathname, "/v1/sessions/:id/plan-approval")
  if (planApprovalSessionId !== undefined && request.method === "DELETE")
    return clearPlanApproval(route, planApprovalSessionId)

  const sessionId = matchRoute(url.pathname, "/v1/sessions/:id")
  if (sessionId !== undefined && request.method === "GET") return readSession(route, sessionId)
  if (sessionId !== undefined && request.method === "PATCH") return updateSession(route, sessionId)
  if (sessionId !== undefined && request.method === "DELETE") return deleteSession(route, sessionId)

  return routeActions(route)
}

const listSessions = async ({ services, response, url }: RouteContext): Promise<boolean> => {
  const parentSessionId = url.searchParams.get("parentSessionId")?.toLowerCase()
  const sessions = await allSessions(services)
  writeJson(
    response,
    200,
    sessions.filter((session) => isListed(session, parentSessionId, url))
  )
  return true
}

const awaitSessions = async ({
  services,
  fanout,
  request,
  response
}: RouteContext): Promise<boolean> => {
  const payload = await readSchema(request, WaitForSessionsRequestSchema)
  const abort = new AbortController()
  response.once("close", () => abort.abort())
  writeJson(response, 200, await waitForSessions(services.db, fanout, payload, abort.signal))
  return true
}

const createSession = async ({
  services,
  fanout,
  routeState,
  request,
  response,
  config
}: RouteContext): Promise<boolean> => {
  const payload = await readSchema(request, CreateSessionRequestSchema)
  const { session, created } = await createSessionIfMissing(
    services,
    fanout,
    routeState,
    config,
    payload
  )
  writeJson(response, created ? 201 : 200, session)
  return true
}

const readBranchDiff = async (
  { services, response }: RouteContext,
  sessionId: string
): Promise<boolean> => {
  const session = foundSession(await findSession(services.db, sessionId))
  const project = await getProjectOrFail(services.db, session.projectId)
  const directory = sessionDirectory(session, project)
  if (directory == null) {
    writeJson(response, 200, null)
    return true
  }

  writeJson(response, 200, (await gitBranchDiffTotals(directory)) ?? null)
  return true
}

const readUsageLimits = async (
  { services, response }: RouteContext,
  sessionId: string
): Promise<boolean> => {
  const session = foundSession(await findSession(services.db, sessionId))
  const { limits, accountId } = await readSessionUsageLimits(services, session)
  const accounts = await services.auth?.accounts(session.harnessId)
  const account = accounts?.find((candidate) => candidate.id === accountId)
  writeJson(response, 200, usageLimitsBody(limits, accountId, account))
  return true
}

const readSessionContext = async (
  { services, response }: RouteContext,
  sessionId: string
): Promise<boolean> => {
  const session = foundSession(await findSession(services.db, sessionId))
  const agentSessionId = session.agentSessionId
  if (!isRuntimeLoaded(services, agentSessionId)) {
    writeJson(response, 200, null)
    return true
  }

  const context = await run(services.agents.readSessionContext(agentSessionId))
  writeJson(response, 200, context ?? null)
  return true
}

const markRead = async (
  { services, fanout, request, response }: RouteContext,
  sessionId: string
): Promise<boolean> => {
  const payload = await readSchema(request, MarkSessionReadRequestSchema)
  const session = await run(services.db.markSessionRead(sessionId, payload.throughSequence))
  await publishAttention(services, fanout, session)
  writeJson(response, 200, session)
  return true
}

const markUnread = async (
  { services, fanout, response }: RouteContext,
  sessionId: string
): Promise<boolean> => {
  const session = await run(services.db.markSessionUnread(sessionId))
  await publishAttention(services, fanout, session)
  writeJson(response, 200, session)
  return true
}

const clearPlanApproval = async (
  { services, fanout, response }: RouteContext,
  sessionId: string
): Promise<boolean> => {
  const session = await run(services.db.clearSessionPlanApproval(sessionId))
  await publishAttention(services, fanout, session)
  writeJson(response, 204, undefined)
  return true
}

const readSession = async (
  { services, routeState, response }: RouteContext,
  sessionId: string
): Promise<boolean> => {
  writeJson(
    response,
    200,
    await withAutoResume(
      services.db,
      withUpdateGate(
        await run(services.db.getSessionDetail(sessionId)),
        services,
        routeState,
        sessionId
      ),
      sessionId
    )
  )
  return true
}

const updateSession = async (
  { services, fanout, request, response, config }: RouteContext,
  sessionId: string
): Promise<boolean> => {
  const payload = await readSchema(request, UpdateSessionRequestSchema)
  if (payload.projectId !== undefined) {
    const before = await run(services.db.getSessionSummary(sessionId))
    if (agentAlreadyStarted(before)) {
      throw new HttpFailure(
        409,
        "Session agent already started; its working directory can no longer move"
      )
    }
    const project = await getProjectOrFail(services.db, payload.projectId)
    await resolveSessionCwdOrFail(services, config.id, project, payload.worktreeName)
  }

  const session = await applySessionUpdate(services, fanout, sessionId, payload)
  writeJson(response, 200, session)
  return true
}

const deleteSession = async (
  { services, fanout, response }: RouteContext,
  sessionId: string
): Promise<boolean> => {
  await assertNotOwnedByBot(services, { sessionId }, "delete this chat")
  const workspaceId = workspaceOf(await allSessions(services), sessionId)
  await services.mcp?.closeSession(sessionId)
  await run(services.db.deleteSession(sessionId))
  await appendAndPublish(services.db, fanout, "session.deleted", sessionId, { id: sessionId })

  if (workspaceId != null && !hasSessionIn(await allSessions(services), workspaceId)) {
    await run(services.db.deleteWorkspace(workspaceId))
    await appendAndPublish(services.db, fanout, "workspace.deleted", workspaceId, {
      id: workspaceId
    })
  }

  writeJson(response, 204, undefined)
  return true
}

const routeActions = async (route: RouteContext): Promise<boolean> => {
  if (await routeSessionActions(route)) {
    return true
  }

  return false
}

const allSessions = (services: CodevisorServerServices): Promise<ReadonlyArray<SessionSummary>> =>
  run(services.db.listSessions)

const isListed = (
  session: SessionSummary,
  parentSessionId: string | undefined,
  url: URL
): boolean =>
  (parentSessionId === undefined || session.parentSessionId === parentSessionId) &&
  matchesLabelFilters(session.labels, url)

const foundSession = (session: SessionSummary | undefined): SessionSummary => {
  if (session === undefined) throw new HttpFailure(404, "Session not found")
  return session
}

const sessionDirectory = (session: SessionSummary, project: Project): string | undefined =>
  session.cwd ??
  project.locations.find((location) => location.serverId === session.serverId)?.folderPath

const usageLimitsBody = (
  limits: HarnessUsageLimits,
  accountId: string | undefined,
  account: HarnessAccount | undefined
): HarnessUsageLimits => ({
  ...limits,
  ...(accountId === undefined ? {} : { accountId }),
  ...(account === undefined ? {} : { accountEmail: account.email, accountLabel: account.label })
})

const isRuntimeLoaded = (
  services: CodevisorServerServices,
  agentSessionId: string | undefined
): agentSessionId is string =>
  agentSessionId !== undefined && services.agents.loadedAgentSessionIds().includes(agentSessionId)

const publishAttention = (
  services: CodevisorServerServices,
  fanout: EventFanout,
  session: SessionSummary
): Promise<unknown> =>
  appendAndPublish(services.db, fanout, "session.attention.updated", session.id, session)

const agentAlreadyStarted = (session: SessionSummary): boolean =>
  session.agentSessionId !== undefined && session.agentSessionId !== ""

const workspaceOf = (
  sessions: ReadonlyArray<SessionSummary>,
  sessionId: string
): string | null | undefined => sessions.find((session) => session.id === sessionId)?.workspaceId

const hasSessionIn = (sessions: ReadonlyArray<SessionSummary>, workspaceId: string): boolean =>
  sessions.some((session) => session.workspaceId === workspaceId)
