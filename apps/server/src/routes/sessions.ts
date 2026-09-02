import type { HarnessUsageLimits } from "@codevisor/api"
import {
  MarkSessionReadRequest as MarkSessionReadRequestSchema,
  CreateSessionRequest as CreateSessionRequestSchema,
  UpdateSessionRequest as UpdateSessionRequestSchema
} from "@codevisor/api"
import type { IncomingMessage, ServerResponse } from "node:http"
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
import {
  applySessionUpdate,
  createSessionIfMissing,
  findSession,
  resolveSessionCwdOrFail
} from "./session-workspace.js"
import { routeSessionActions } from "./session-actions.js"

export {
  drainPromptQueue,
  makeTurnDispatchListener,
  reconcileOrphanedSessionTurns,
  reconcileStaleStreamingTurns
} from "./prompt-queue.js"

export const MAX_PROMPT_ATTACHMENTS = 10

export const routeSessions = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  routeState: RouteState,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL,
  config: CodevisorServerConfig
): Promise<boolean> => {
  if (request.method === "GET" && url.pathname === "/v1/sessions") {
    writeJson(response, 200, await run(services.db.listSessions))
    return true
  }

  if (request.method === "POST" && url.pathname === "/v1/sessions") {
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

  const branchDiffSessionId = matchRoute(url.pathname, "/v1/sessions/:id/branch-diff")
  if (branchDiffSessionId !== undefined && request.method === "GET") {
    const session = await findSession(services.db, branchDiffSessionId)
    if (session === undefined) throw new HttpFailure(404, "Session not found")
    const project = await getProjectOrFail(services.db, session.projectId)
    const directory =
      session.cwd ??
      project.locations.find((location) => location.serverId === session.serverId)?.folderPath
    writeJson(
      response,
      200,
      directory == null ? null : ((await gitBranchDiffTotals(directory)) ?? null)
    )
    return true
  }

  const usageLimitsSessionId = matchRoute(url.pathname, "/v1/sessions/:id/usage-limits")
  if (usageLimitsSessionId !== undefined && request.method === "GET") {
    const session = await findSession(services.db, usageLimitsSessionId)
    if (session === undefined) throw new HttpFailure(404, "Session not found")
    const project = await getProjectOrFail(services.db, session.projectId)
    const cwd =
      session.cwd ??
      project.locations.find((location) => location.serverId === session.serverId)?.folderPath
    if (cwd === undefined) {
      const unavailable: HarnessUsageLimits = {
        detail: "This session has no local workspace from which to query its harness.",
        fetchedAt: new Date().toISOString(),
        harnessId: session.harnessId,
        state: "unavailable",
        windows: []
      }
      writeJson(response, 200, unavailable)
      return true
    }
    const accountContext =
      session.harnessAccountId === undefined
        ? await services.auth?.activeAccountContext(session.harnessId)
        : await services.auth?.accountContext(session.harnessAccountId)
    const limits = await run(
      services.agents.readHarnessUsageLimits(session.harnessId, cwd, accountContext)
    )
    const accountId = session.harnessAccountId ?? accountContext?.id
    const accounts = await services.auth?.accounts(session.harnessId)
    const account = accounts?.find((candidate) => candidate.id === accountId)
    writeJson(response, 200, {
      ...limits,
      ...(accountId === undefined ? {} : { accountId }),
      ...(account === undefined ? {} : { accountEmail: account.email, accountLabel: account.label })
    })
    return true
  }

  const readSessionId = matchRoute(url.pathname, "/v1/sessions/:id/read")
  if (readSessionId !== undefined && request.method === "POST") {
    const payload = await readSchema(request, MarkSessionReadRequestSchema)
    const session = await run(services.db.markSessionRead(readSessionId, payload.throughSequence))
    await appendAndPublish(services.db, fanout, "session.attention.updated", session.id, session)
    writeJson(response, 200, session)
    return true
  }

  const unreadSessionId = matchRoute(url.pathname, "/v1/sessions/:id/unread")
  if (unreadSessionId !== undefined && request.method === "POST") {
    const session = await run(services.db.markSessionUnread(unreadSessionId))
    await appendAndPublish(services.db, fanout, "session.attention.updated", session.id, session)
    writeJson(response, 200, session)
    return true
  }

  const planApprovalSessionId = matchRoute(url.pathname, "/v1/sessions/:id/plan-approval")
  if (planApprovalSessionId !== undefined && request.method === "DELETE") {
    const session = await run(services.db.clearSessionPlanApproval(planApprovalSessionId))
    await appendAndPublish(services.db, fanout, "session.attention.updated", session.id, session)
    writeJson(response, 204, undefined)
    return true
  }

  const sessionId = matchRoute(url.pathname, "/v1/sessions/:id")
  if (sessionId !== undefined && request.method === "GET") {
    writeJson(response, 200, await run(services.db.getSessionDetail(sessionId)))
    return true
  }

  if (sessionId !== undefined && request.method === "PATCH") {
    const payload = await readSchema(request, UpdateSessionRequestSchema)
    if (payload.projectId !== undefined) {
      // A project move re-homes the session's working directory, which is
      // only safe while the agent hasn't started (its cwd binds at spawn).
      const before = await run(services.db.getSessionSummary(sessionId))
      if (before.agentSessionId !== undefined && before.agentSessionId !== "") {
        throw new HttpFailure(
          409,
          "Session agent already started; its working directory can no longer move"
        )
      }
      const project = await getProjectOrFail(services.db, payload.projectId)
      // Fail the move up front if the destination doesn't resolve on this
      // machine (missing folder, unknown worktree) rather than at first send.
      await resolveSessionCwdOrFail(services, config.id, project, payload.worktreeName)
    }
    const session = await applySessionUpdate(services, fanout, config, sessionId, payload)
    writeJson(response, 200, session)
    return true
  }

  if (sessionId !== undefined && request.method === "DELETE") {
    // Capture the workspace link before the row disappears: deleting the
    // LAST session of a workspace deletes the workspace too, mirroring the
    // client's archive-last-chat behavior. Without this, out-of-band session
    // deletion strands empty workspaces in every client's sidebar.
    const workspaceId = (await run(services.db.listSessions)).find(
      (session) => session.id === sessionId
    )?.workspaceId
    await services.mcp?.closeSession(sessionId)
    await run(services.db.deleteSession(sessionId))
    await appendAndPublish(services.db, fanout, "session.deleted", sessionId, { id: sessionId })
    if (workspaceId != null) {
      const remaining = (await run(services.db.listSessions)).some(
        (session) => session.workspaceId === workspaceId
      )
      if (!remaining) {
        await run(services.db.deleteWorkspace(workspaceId))
        await appendAndPublish(services.db, fanout, "workspace.deleted", workspaceId, {
          id: workspaceId
        })
      }
    }
    writeJson(response, 204, undefined)
    return true
  }

  if (await routeSessionActions(services, fanout, routeState, request, response, url, config)) {
    return true
  }

  return false
}
