import type { AgentSessionMetadata, RuntimeEvent, RuntimeEventSink } from "@codevisor/agent-runtime"
import { randomUUID } from "node:crypto"
import type {
  AttachmentRef,
  CreateSessionRequest,
  UpdateSessionRequest,
  EventEnvelope,
  HarnessUsageLimits,
  Project,
  PromptAcceptedResponse,
  PromptQueueItem,
  SessionConfigOption,
  SessionSummary
} from "@codevisor/api"
import {
  MarkSessionReadRequest as MarkSessionReadRequestSchema,
  CreateSessionRequest as CreateSessionRequestSchema,
  OpenSessionRequest as OpenSessionRequestSchema,
  CancelRequest,
  PromptRequest,
  SetConfigRequest,
  SetGoalRequest,
  SetModeRequest,
  SetQuestionAnswerRequest,
  UpdateQueuedPromptRequest,
  UpdateSessionRequest as UpdateSessionRequestSchema,
  isoTimestamp
} from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"
import type { IncomingMessage, ServerResponse } from "node:http"
import { gitBranchDiffTotals } from "@codevisor/worktrees"
import {
  appendAndPublish,
  archiveSessionRuntime,
  archiveSessionWorktree,
  assertLocationFolderExists,
  existingDirectory,
  failureMessage,
  getProjectOrFail,
  HttpFailure,
  localLocationOrFail,
  matchRoute,
  matchRouteParams,
  readSchema,
  resolvePromptAttachments,
  restoreSessionWorktree,
  run,
  swallowError,
  writeJson,
  type CodevisorServerConfig,
  type CodevisorServerServices,
  type EventFanout,
  type RouteState
} from "../server-context.js"

const MAX_PROMPT_ATTACHMENTS = 10

export const reconcileOrphanedSessionTurns = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string
): Promise<void> => {
  const sessions = await run(services.db.listSessions)
  for (const session of sessions) {
    if (session.isArchived) {
      // Archived sessions get no turn restoration, but a stale streaming row
      // must still be closed — unarchiving would otherwise resurface it as an
      // endless in-progress turn.
      await run(
        services.db.failStaleAssistantChatItems(
          session.id,
          "The server restarted before this response finished."
        )
      )
      continue
    }
    const page = await run(services.db.getTranscriptPage(session.id, undefined, 1))
    const active = page.items.at(-1)
    const hasOrphanedTurn = active?.role === "assistant" && active.isGenerating
    // Reconciliation runs before the server accepts clients, so no live turn
    // exists anywhere: every streaming row is dead. The newest item is closed
    // by the turn-ending path below with full restore context; older rows —
    // stranded mid-transcript when a previous process died or a concurrent
    // writer stole the projection pointer — would otherwise render as an
    // endless in-progress turn that no future event can ever finish.
    await run(
      services.db.failStaleAssistantChatItems(
        session.id,
        "The server restarted before this response finished.",
        hasOrphanedTurn ? active.id : undefined
      )
    )
    // The database projection always supplies the full background-task
    // snapshot; the API field is optional only for older remote clients.
    const hasOrphanedTasks = page.backgroundTasks!.length > 0
    const claimedPrompts = await run(services.db.listProcessingPromptQueue(session.id))
    const processingPrompts: Array<PromptQueueItem> = []
    for (const item of claimedPrompts) {
      if (await run(services.db.hasTerminalAssistantAfterMessage(session.id, item.id))) {
        // The provider finished and only the queue acknowledgement was lost.
        // Its terminal chat row is sufficient proof that replay is unnecessary.
        await run(services.db.completePromptQueueItem(session.id, item.id))
      } else {
        processingPrompts.push(item)
      }
    }
    if (!hasOrphanedTurn && !hasOrphanedTasks && processingPrompts.length === 0) continue

    // The provider-side resolver vanished with the old process. Pair a
    // persisted question before ending the turn so event replay never leaves
    // an apparently answerable request behind.
    if (hasOrphanedTurn && page.pendingQuestion !== undefined) {
      await appendAndPublish(services.db, fanout, "session.output", session.id, {
        outcome: "cancelled",
        questionId: page.pendingQuestion.questionId,
        questions: page.pendingQuestion.questions,
        sessionUpdate: "question_resolved",
        serverId
      })
    }

    // Process-owned background tasks cannot survive the same crash. Publish a
    // full empty snapshot before the terminal event so another crash can never
    // persist the terminal row while leaving stale work behind. If startup
    // dies between these appends, the still-generating turn is reconciled again.
    if (hasOrphanedTasks) {
      await appendAndPublish(services.db, fanout, "session.updated", session.id, {
        backgroundTasks: [],
        serverId
      })
    }
    // A prompt remains durably claimed until its provider call finishes. If
    // the process died while dispatching it, make sure the user's input is
    // represented exactly once, then create a deterministic interrupted turn
    // when the provider had not emitted one yet. The claim is acknowledged
    // only after another durable generating row exists, so every crash point
    // leaves at least one marker for the next startup pass to reconcile.
    for (const item of processingPrompts) {
      if (!(await run(services.db.hasConversationMessage(session.id, item.id)))) {
        await appendAndPublish(services.db, fanout, "session.output", session.id, {
          role: "user",
          messageId: item.id,
          text: item.text,
          ...(item.attachments === undefined ? {} : { attachments: item.attachments }),
          serverId
        })
      }
    }

    let terminalTurnId = hasOrphanedTurn ? active.turnId : undefined
    if (!hasOrphanedTurn && processingPrompts.length > 0) {
      terminalTurnId = `recovered-prompt:${processingPrompts[0]!.id}`
      await appendAndPublish(services.db, fanout, "session.updated", session.id, {
        initiatedBy: "user",
        turnId: terminalTurnId,
        turnState: "started",
        serverId
      })
    }
    for (const item of processingPrompts) {
      await run(services.db.completePromptQueueItem(session.id, item.id))
    }

    if (!hasOrphanedTurn && terminalTurnId === undefined) continue

    await appendAndPublish(services.db, fanout, "session.updated", session.id, {
      ...(terminalTurnId === undefined
        ? {}
        : { initiatedBy: "user", turnId: terminalTurnId, turnState: "ended" }),
      serverId,
      stopDetail:
        "The server restarted before this turn finished. Reopen the chat to reconnect its agent session, then send a message to continue.",
      stopReason: "interrupted"
    })
  }
}

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
    await services.mcp?.closeSession(sessionId)
    await run(services.db.deleteSession(sessionId))
    await appendAndPublish(services.db, fanout, "session.deleted", sessionId, { id: sessionId })
    writeJson(response, 204, undefined)
    return true
  }

  if (await routeSessionActions(services, fanout, routeState, request, response, url, config)) {
    return true
  }

  return false
}

const createServerSession = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  payload: CreateSessionRequest,
  project: Project
): Promise<SessionSummary> => {
  const cwd = await resolveSessionCwdOrFail(services, serverId, project, payload.worktreeName)
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
  const harnessAccountId = payload.harnessAccountId ?? accountContext?.id
  await ensureSessionWorkspace(
    services,
    fanout,
    payload.workspaceId,
    project,
    payload.worktreeName ?? project.name,
    cwd
  )
  // The session id is generated up front so the standing event sink can bind
  // to it before the agent session exists.
  const sessionId = payload.id ?? randomUUID()
  const sink = sessionEventSink(services, fanout, serverId, sessionId)
  const toolGateway = await services.mcp?.issueGateway(sessionId, project.id, sink)
  const agentSessionId =
    payload.deferAgentSession === true
      ? ""
      : (payload.agentSessionId ??
        (await run(
          services.agents.createAgentSession(
            payload.harnessId,
            cwd,
            sink,
            accountContext,
            toolGateway
          )
        )))
  return run(
    services.db.createSession({
      ...payload,
      id: sessionId,
      // Use the resolved project's canonical id (the client may have sent a
      // different-cased UUID) so the session's foreign key matches the row.
      projectId: project.id,
      ...(harnessAccountId === undefined ? {} : { harnessAccountId }),
      agentSessionId
    })
  )
}

/// Create-or-return for sessions: the existing-row and in-flight-create
/// checks (concurrent POSTs for the same client-supplied id must not spawn
/// two agent sessions) shared by POST /v1/sessions and the combined
/// /open route.
const createSessionIfMissing = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  routeState: RouteState,
  config: CodevisorServerConfig,
  rawPayload: CreateSessionRequest
): Promise<{ readonly session: SessionSummary; readonly created: boolean }> => {
  // Session ids are canonically lowercase; a client-supplied uppercase id
  // (Swift renders uuids uppercase) must find the existing row — and share
  // the in-flight-create key — rather than minting a case-twin duplicate.
  const payload: CreateSessionRequest =
    rawPayload.id === undefined ? rawPayload : { ...rawPayload, id: rawPayload.id.toLowerCase() }
  if (payload.id !== undefined) {
    const existing = await findSession(services.db, payload.id)
    if (existing !== undefined) {
      return { session: existing, created: false }
    }
    const pending = routeState.pendingSessionCreates.get(payload.id)
    if (pending !== undefined) {
      return { session: await pending, created: false }
    }
  }
  const project = await getProjectOrFail(services.db, payload.projectId)
  const create = createServerSession(services, fanout, config.id, payload, project)
  if (payload.id !== undefined) {
    routeState.pendingSessionCreates.set(payload.id, create)
  }
  const session = await create.finally(() => {
    if (payload.id !== undefined) {
      routeState.pendingSessionCreates.delete(payload.id)
    }
  })
  await appendAndPublish(services.db, fanout, "session.created", session.id, session)
  return { session, created: true }
}

/// The full PATCH side-effect set — archive teardown and the
/// updated/archived event fanout — shared by PATCH /v1/sessions/:id and the
/// combined /open route so opening a chat behaves exactly like the discrete
/// update it replaced.
const applySessionUpdate = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  config: CodevisorServerConfig,
  sessionId: string,
  payload: UpdateSessionRequest
): Promise<SessionSummary> => {
  const before = await findSession(services.db, sessionId)
  const wasArchived = before?.isArchived === true
  if (payload.workspaceId !== undefined && before !== undefined) {
    const project = await getProjectOrFail(services.db, payload.projectId ?? before.projectId)
    await ensureSessionWorkspace(
      services,
      fanout,
      payload.workspaceId,
      project,
      payload.worktreeName ?? before.worktreeName ?? project.name,
      before.cwd
    )
  }
  let session = await run(services.db.updateSession(sessionId, payload))
  if (payload.workspaceId !== undefined) {
    await run(services.db.setSessionWorkspace(sessionId, payload.workspaceId))
    session = await run(services.db.getSessionSummary(sessionId))
  }

  if (session.isArchived && !wasArchived) {
    await archiveSessionRuntime(services, session)
    const ignored = await archiveSessionWorktree(services, config.id, session)
    if (ignored.length > 0) {
      // Gitignored files are deliberately not snapshotted (they can hold
      // secrets and are usually regenerable). Tell the client which ones went
      // away with the worktree rather than losing them silently.
      await appendAndPublish(services.db, fanout, "session.updated", session.id, {
        ...session,
        archiveDroppedIgnoredPaths: ignored
      })
    }
  } else if (!session.isArchived && wasArchived) {
    const restored = await restoreSessionWorktree(services, config.id, session)
    session = restored.session
    if (!restored.restoredFiles) {
      await appendAndPublish(services.db, fanout, "session.updated", session.id, {
        ...session,
        archiveRestoreIncomplete: true
      })
    }
  }

  await appendAndPublish(
    services.db,
    fanout,
    session.isArchived
      ? "session.archived"
      : wasArchived
        ? "session.unarchived"
        : "session.updated",
    session.id,
    session
  )
  return session
}

/// Native clients persist pane layout locally, but workspace identity and
/// membership are server-owned. A chat may reach the server before its local
/// workspace has ever been uploaded, so assigning the chat lazily creates the
/// metadata row first. The event lets every other client materialize its own
/// local layout for the shared workspace.
const ensureSessionWorkspace = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  workspaceId: string | undefined,
  project: Project,
  workspaceName: string,
  rootDirectory: string | undefined
): Promise<void> => {
  if (workspaceId === undefined) return
  const canonical = workspaceId.toLowerCase()
  const existing = (await run(services.db.listWorkspaces)).find(
    (workspace) => workspace.id.toLowerCase() === canonical
  )
  if (existing !== undefined) {
    if (existing.projectId.toLowerCase() !== project.id.toLowerCase()) {
      throw new HttpFailure(
        409,
        `Workspace ${workspaceId} belongs to project ${existing.projectId}, not ${project.id}`
      )
    }
    return
  }
  const workspace = await run(
    services.db.upsertWorkspace({
      id: canonical,
      projectId: project.id,
      name: workspaceName,
      hasCustomName: false,
      symbolName: project.symbolName,
      /* v8 ignore next -- server-created sessions always resolve a cwd; omission protects legacy rows without a local project location. */
      ...(rootDirectory === undefined ? {} : { rootDirectory })
    })
  )
  await appendAndPublish(services.db, fanout, "workspace.updated", workspace.id, workspace)
}

/// The standing per-session sink: every runtime event — in-turn or
/// agent-initiated — is persisted and fanned out here. User echoes are
/// filtered because the server materializes its own copy when a prompt is
/// accepted.
const sessionEventSink =
  (
    services: CodevisorServerServices,
    fanout: EventFanout,
    serverId: string,
    sessionId: string
  ): RuntimeEventSink =>
  (event) => {
    if (isUserRuntimeEvent(event)) {
      return
    }
    if (event.kind === "session.authRequired") {
      return (async () => {
        const session = await run(services.db.getSessionSummary(sessionId))
        const detail =
          isRecord(event.payload) && typeof event.payload.detail === "string"
            ? event.payload.detail
            : undefined
        /* v8 ignore next -- sessions with and without pinned accounts are integration-tested. */
        if (session?.harnessAccountId !== undefined) {
          await services.auth?.markAccountExpired(session.harnessAccountId, detail)
        }
        await materializeRuntimeEvent(services.db, fanout, serverId, event, sessionId)
      })()
    }
    const payload = objectPayload(event.payload)
    if (
      event.kind === "session.error" ||
      (event.kind === "session.updated" &&
        (payload.turnState === "ended" || typeof payload.stopReason === "string"))
    ) {
      return materializeRuntimeEvent(services.db, fanout, serverId, event, sessionId)
    }
    return materializeRuntimeEvent(services.db, fanout, serverId, event, sessionId)
  }

/// Derives the directory a session runs in: the project's folder on this
/// server, or its worktree at ~/codevisor/{projectId}/{worktreeName}. The result
/// must stay deterministic per session so the agent-runtime session cache hits.
const resolveSessionCwdOrFail = async (
  services: CodevisorServerServices,
  serverId: string,
  project: Project,
  worktreeName: string | undefined
): Promise<string> => {
  const location = localLocationOrFail(serverId, project)
  if (worktreeName === undefined) {
    assertLocationFolderExists(location)
    return location.folderPath
  }
  const worktree = (await run(services.db.listWorktrees(project.id))).find(
    (candidate) => candidate.name === worktreeName && candidate.serverId === serverId
  )
  if (worktree === undefined) {
    throw new HttpFailure(400, `Worktree not found for project ${project.id}: ${worktreeName}`)
  }
  if (existingDirectory(worktree.path) === undefined) {
    throw new HttpFailure(400, `Worktree folder does not exist: ${worktree.path}`)
  }
  return worktree.path
}

const findSession = async (
  db: CodevisorDatabaseService,
  id: string
): Promise<SessionSummary | undefined> => {
  try {
    return await run(db.getSessionSummary(id))
  } catch {
    return undefined
  }
}

const routeSessionActions = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  routeState: RouteState,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL,
  config: CodevisorServerConfig
): Promise<boolean> => {
  const connectSessionId = matchRoute(url.pathname, "/v1/sessions/:id/connect")
  if (connectSessionId !== undefined && request.method === "POST") {
    const metadata = await ensureAgentSessionFor(services, fanout, config.id, connectSessionId)
    writeJson(response, 200, metadata)
    return true
  }

  // One-round-trip chat open: ensure the project and session records exist
  // and return the first transcript page together, replacing the client's
  // listProjects → createProject → listSessions → create/update → transcript
  // waterfall. Deliberately does NOT touch the agent runtime — clients call
  // /connect in parallel so the transcript can paint while the agent process
  // is still spawning. Older clients keep using the discrete routes; newer
  // clients fall back to them when this route 404s on an older server.
  const openSessionId = matchRoute(url.pathname, "/v1/sessions/:id/open")
  if (openSessionId !== undefined && request.method === "POST") {
    const payload = await readSchema(request, OpenSessionRequestSchema)
    if (
      payload.session.id !== undefined &&
      payload.session.id.toLowerCase() !== openSessionId.toLowerCase()
    ) {
      throw new HttpFailure(400, "Session id in body does not match the path")
    }
    const limit = payload.transcriptLimit ?? 32
    if (!Number.isSafeInteger(limit) || limit < 1) {
      throw new HttpFailure(400, "Invalid transcript page limit")
    }
    // Project: create-if-missing. An existing record is never updated from
    // the open snapshot — it may predate changes made elsewhere (archiving),
    // and opening a chat must not revert them.
    if (payload.project?.id !== undefined) {
      const wanted = payload.project.id.toLowerCase()
      const exists = (await run(services.db.listProjects)).some(
        (candidate) => candidate.id.toLowerCase() === wanted
      )
      if (!exists) {
        const project = await run(services.db.createProject(payload.project))
        await appendAndPublish(services.db, fanout, "project.created", project.id, project)
      }
    }
    const existing = await findSession(services.db, openSessionId)
    const session =
      existing === undefined
        ? (
            await createSessionIfMissing(services, fanout, routeState, config, {
              ...payload.session,
              id: openSessionId
            })
          ).session
        : payload.update === undefined
          ? existing
          : await applySessionUpdate(services, fanout, config, openSessionId, payload.update)
    const transcript = await run(services.db.getTranscriptPage(openSessionId, undefined, limit))
    writeJson(response, 200, { session, transcript })
    return true
  }

  const transcriptSessionId = matchRoute(url.pathname, "/v1/sessions/:id/transcript")
  if (transcriptSessionId !== undefined && request.method === "GET") {
    const rawBefore = url.searchParams.get("before")
    const before = rawBefore === null ? undefined : Number(rawBefore)
    if (before !== undefined && (!Number.isSafeInteger(before) || before < 0)) {
      throw new HttpFailure(400, "Invalid transcript cursor")
    }
    const rawLimit = url.searchParams.get("limit")
    const limit = rawLimit === null ? 32 : Number(rawLimit)
    if (!Number.isSafeInteger(limit) || limit < 1) {
      throw new HttpFailure(400, "Invalid transcript page limit")
    }
    writeJson(
      response,
      200,
      await run(services.db.getTranscriptPage(transcriptSessionId, before, limit))
    )
    return true
  }

  const transcriptDetails = matchRouteParams(
    url.pathname,
    "/v1/sessions/:id/transcript/:itemId/details"
  )
  if (transcriptDetails !== undefined && request.method === "GET") {
    const { id, itemId } = transcriptDetails as { readonly id: string; readonly itemId: string }
    const details = await run(services.db.getTranscriptItemDetails(id, itemId))
    if (details === undefined) {
      throw new HttpFailure(404, `Transcript item not found: ${itemId}`)
    }
    writeJson(response, 200, details)
    return true
  }

  const queueSessionId = matchRoute(url.pathname, "/v1/sessions/:id/queue")
  if (queueSessionId !== undefined && request.method === "GET") {
    writeJson(response, 200, await run(services.db.listPromptQueue(queueSessionId)))
    return true
  }

  // Full persisted event history for one session — the client replays these
  // through its live pipeline to rebuild rich transcripts (tool calls, diffs)
  // that the text-only conversation snapshot cannot carry.
  const eventsSessionId = matchRoute(url.pathname, "/v1/sessions/:id/events")
  if (eventsSessionId !== undefined && request.method === "GET") {
    writeJson(
      response,
      200,
      await sessionHistoryEventsWithSetup(services.db, config.id, eventsSessionId)
    )
    return true
  }

  const queueItemRoute = matchRouteParams(url.pathname, "/v1/sessions/:id/queue/:queueId")
  if (queueItemRoute !== undefined && request.method === "PATCH") {
    const { id, queueId } = queueItemRoute as { readonly id: string; readonly queueId: string }
    const payload = await readSchema(request, UpdateQueuedPromptRequest)
    const item = await run(services.db.updatePromptQueueItem(id, queueId, payload.text))
    await publishPromptQueue(services.db, fanout, id)
    writeJson(response, 200, item)
    return true
  }

  if (queueItemRoute !== undefined && request.method === "DELETE") {
    const { id, queueId } = queueItemRoute as { readonly id: string; readonly queueId: string }
    await run(services.db.deletePromptQueueItem(id, queueId))
    await publishPromptQueue(services.db, fanout, id)
    writeNoContent(response)
    return true
  }

  const promptSessionId = matchRoute(url.pathname, "/v1/sessions/:id/prompt")
  if (promptSessionId !== undefined && request.method === "POST") {
    const payload = await readSchema(request, PromptRequest)
    const actionKey = actionIdKey(promptSessionId, payload.clientActionId)
    if (payload.clientActionId !== undefined) {
      const existing = await run(
        services.db.getSessionActionResult(promptSessionId, payload.clientActionId)
      )
      if (existing !== undefined) {
        writeJson(response, 202, existing)
        return true
      }
    }
    /* v8 ignore next 4 -- duplicate in-flight requests normally hit the saved idempotency row above. */
    if (actionKey !== undefined && routeState.pendingPromptActions.has(actionKey)) {
      writeJson(response, 202, { accepted: true, sessionId: promptSessionId })
      return true
    }
    const attachments = payload.attachments ?? []
    if (attachments.length > MAX_PROMPT_ATTACHMENTS) {
      throw new HttpFailure(422, `A prompt may carry at most ${MAX_PROMPT_ATTACHMENTS} attachments`)
    }
    // Fail unknown file ids at send time rather than mid-drain.
    for (const attachment of attachments) {
      if ((await run(services.db.getFileMetadata(attachment.fileId))) === undefined) {
        throw new HttpFailure(422, `Unknown attachment file: ${attachment.fileId}`)
      }
    }
    if (actionKey !== undefined) {
      routeState.pendingPromptActions.add(actionKey)
    }
    const queueItem = await run(
      services.db.createPromptQueueItem(
        promptSessionId,
        payload.text,
        attachments,
        payload.messageId
      )
    )
    const result: PromptAcceptedResponse = {
      accepted: true,
      sessionId: promptSessionId,
      queueItemId: queueItem.id
    }
    if (payload.clientActionId !== undefined) {
      await run(
        services.db.saveSessionActionResult(
          promptSessionId,
          payload.clientActionId,
          "prompt",
          result
        )
      )
    }
    writeJson(response, 202, result)
    void drainPromptQueue(services, fanout, routeState, config.id, promptSessionId)
      .catch(swallowError)
      .finally(() => {
        if (actionKey !== undefined) {
          routeState.pendingPromptActions.delete(actionKey)
        }
      })
    return true
  }

  const cancelSessionId = matchRoute(url.pathname, "/v1/sessions/:id/cancel")
  if (cancelSessionId !== undefined && request.method === "POST") {
    const payload = await readSchema(request, CancelRequest)
    await writeIdempotentAction(
      services,
      response,
      cancelSessionId,
      "cancel",
      payload,
      async () => {
        const cancelRequestedAt = isoTimestamp()
        const session = await run(services.db.getSessionSummary(cancelSessionId))
        const activeItem = (
          await run(services.db.getTranscriptPage(cancelSessionId, undefined, 1))
        ).items.at(-1)
        const agentSession = await ensureAgentSessionFor(
          services,
          fanout,
          config.id,
          cancelSessionId
        )
        const outcome = await run(services.agents.cancel(agentSession.sessionId))
        if (outcome.runtimeState === "retire") {
          const forcedAt = isoTimestamp()
          console.error(
            JSON.stringify({
              event: "agent_cancel_forced",
              sessionId: cancelSessionId,
              harnessId: session.harnessId,
              agentSessionId: agentSession.sessionId,
              turnId: activeItem?.turnId,
              providerPhase: "cancelling",
              lastEventType: "durable_transcript_snapshot",
              lastEventAt: activeItem?.updatedAt,
              cancelRequestedAt,
              forcedAt,
              runtimeRetired: true,
              bootId: config.bootId,
              processId: config.processId,
              version: config.version,
              buildNumber: config.buildNumber,
              sourceRevision: config.sourceRevision
            })
          )
        }
        return { cancelled: true }
      }
    )
    return true
  }

  const modeSessionId = matchRoute(url.pathname, "/v1/sessions/:id/mode")
  if (modeSessionId !== undefined && request.method === "POST") {
    const payload = await readSchema(request, SetModeRequest)
    await writeIdempotentAction(services, response, modeSessionId, "mode", payload, async () => {
      const agentSession = await ensureAgentSessionFor(services, fanout, config.id, modeSessionId)
      await run(services.agents.setMode(agentSession.sessionId, payload.modeId))
      return { modeId: payload.modeId }
    })
    return true
  }

  const configSessionId = matchRoute(url.pathname, "/v1/sessions/:id/config")
  if (configSessionId !== undefined && request.method === "POST") {
    const payload = await readSchema(request, SetConfigRequest)
    await writeIdempotentAction(
      services,
      response,
      configSessionId,
      "config",
      payload,
      async () => {
        const agentSession = await ensureAgentSessionFor(
          services,
          fanout,
          config.id,
          configSessionId
        )
        const configOptions = await run(
          services.agents.setConfigOption(agentSession.sessionId, payload.configId, payload.value)
        )
        await run(
          services.db.replaceSessionConfigSelections(
            configSessionId,
            configSelectionsFromOptions(configOptions)
          )
        )
        return { configId: payload.configId }
      }
    )
    return true
  }

  const goalSessionId = matchRoute(url.pathname, "/v1/sessions/:id/goal")
  if (goalSessionId !== undefined && request.method === "POST") {
    const payload = await readSchema(request, SetGoalRequest)
    await writeIdempotentAction(services, response, goalSessionId, "goal", payload, async () => {
      const agentSession = await ensureAgentSessionFor(services, fanout, config.id, goalSessionId)
      // Double-option passthrough: only forward the tokenBudget key when the
      // client sent one (absent = keep, null = clear, number = set).
      return await run(
        services.agents.setGoal(agentSession.sessionId, {
          ...(payload.objective === undefined ? {} : { objective: payload.objective }),
          ...(payload.status === undefined ? {} : { status: payload.status }),
          ...("tokenBudget" in payload ? { tokenBudget: payload.tokenBudget ?? null } : {})
        })
      )
    })
    return true
  }
  if (goalSessionId !== undefined && request.method === "DELETE") {
    const agentSession = await ensureAgentSessionFor(services, fanout, config.id, goalSessionId)
    await run(services.agents.clearGoal(agentSession.sessionId))
    writeJson(response, 204, undefined)
    return true
  }

  const answerRoute = matchRouteParams(
    url.pathname,
    "/v1/sessions/:id/questions/:questionId/answer"
  )
  if (answerRoute !== undefined && request.method === "POST") {
    const answerSessionId = answerRoute.id as string
    const questionId = answerRoute.questionId as string
    const payload = await readSchema(request, SetQuestionAnswerRequest)
    await writeIdempotentAction(
      services,
      response,
      answerSessionId,
      "question-answer",
      payload,
      async () => {
        const answer = {
          outcome: payload.outcome,
          ...(payload.answers === undefined ? {} : { answers: payload.answers })
        }
        const handledByAutomation =
          (await services.mcp?.answerQuestion(answerSessionId, questionId, answer)) ?? false
        if (!handledByAutomation) {
          const agentSession = await ensureAgentSessionFor(
            services,
            fanout,
            config.id,
            answerSessionId
          )
          await run(services.agents.answerQuestion(agentSession.sessionId, questionId, answer))
        }
        return { outcome: payload.outcome, questionId }
      }
    )
    return true
  }

  return false
}

const writeIdempotentAction = async (
  services: CodevisorServerServices,
  response: ServerResponse,
  sessionId: string,
  actionKind: string,
  payload: { readonly clientActionId?: string | undefined },
  runAction: () => Promise<unknown>
): Promise<void> => {
  if (payload.clientActionId !== undefined) {
    const existing = await run(
      services.db.getSessionActionResult(sessionId, payload.clientActionId)
    )
    if (existing !== undefined) {
      writeJson(response, 202, existing)
      return
    }
  }
  const result = await runAction()
  if (payload.clientActionId !== undefined) {
    await run(
      services.db.saveSessionActionResult(sessionId, payload.clientActionId, actionKind, result)
    )
  }
  writeJson(response, 202, result)
}

const actionIdKey = (sessionId: string, clientActionId: string | undefined): string | undefined =>
  clientActionId === undefined ? undefined : `${sessionId}:${clientActionId}`

const publishPromptQueue = async (
  db: CodevisorDatabaseService,
  fanout: EventFanout,
  sessionId: string
): Promise<ReadonlyArray<PromptQueueItem>> => {
  const queue = await run(db.listPromptQueue(sessionId))
  await appendAndPublish(db, fanout, "session.queue.updated", sessionId, { queue })
  return queue
}

/// The session's harness id + display name when its harness update gate is
/// closed; undefined when dispatch may proceed. Failures resolve open — a
/// lookup error must never wedge prompt dispatch.
const sessionUpdateGate = async (
  services: CodevisorServerServices,
  sessionId: string
): Promise<{ readonly harnessId: string; readonly harnessName: string } | undefined> => {
  const lifecycle = services.lifecycle
  if (lifecycle === undefined) return undefined
  const session = await run(services.db.getSessionSummary(sessionId)).catch(swallowError)
  if (session === undefined || !lifecycle.isGated(session.harnessId)) return undefined
  const catalogName = services.agents.catalog.find(
    (definition) => definition.id === session.harnessId
  )?.name
  /* v8 ignore next -- defensive: sessions on uncataloged harnesses fall back to the id. */
  return { harnessId: session.harnessId, harnessName: catalogName ?? session.harnessId }
}

export const drainPromptQueue = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  routeState: RouteState,
  serverId: string,
  sessionId: string
): Promise<void> => {
  if (routeState.activePromptSessions.has(sessionId)) {
    // This item really is waiting behind an in-flight prompt, so expose it to
    // clients as queued. The first prompt takes the owner path below and is
    // claimed before any queue snapshot is published; otherwise every normal
    // send briefly flashes as a one-item queue before execution starts.
    await publishPromptQueue(services.db, fanout, sessionId)
    return
  }
  // Harness-update gate: the prompt is already durable in prompt_queue_items
  // and the client has its 202 — holding is simply not claiming. The gate
  // release listener re-drains every held session.
  const gate = await sessionUpdateGate(services, sessionId)
  if (gate !== undefined) {
    const firstHold = !routeState.gatedSessions.has(sessionId)
    routeState.gatedSessions.set(sessionId, gate.harnessId)
    await publishPromptQueue(services.db, fanout, sessionId)
    if (firstHold) {
      await appendAndPublish(services.db, fanout, "session.updateGate.updated", sessionId, {
        harnessId: gate.harnessId,
        harnessName: gate.harnessName,
        state: "waiting"
      }).catch(swallowError)
    }
    return
  }
  routeState.activePromptSessions.add(sessionId)
  // Turn accounting for update-when-idle: the lifecycle manager runs armed
  // updates when a harness's last in-flight turn ends.
  const busyHarnessId = await run(services.db.getSessionSummary(sessionId))
    .then((session) => session.harnessId)
    .catch(swallowError)
  /* v8 ignore next -- defensive: unknown sessions simply skip turn accounting. */
  if (busyHarnessId !== undefined) services.lifecycle?.notifyTurnStarted(busyHarnessId)
  try {
    while (true) {
      // A gate that closed mid-drain (Update Now) holds the *next* item —
      // registering the session so the release re-drains what remains.
      /* v8 ignore start -- timing-dependent: requires the gate to close between
         two queue claims. The hold/release semantics are covered by the
         pre-drain gate path and the lifecycle manager's gating tests. */
      if (
        services.lifecycle !== undefined &&
        busyHarnessId !== undefined &&
        services.lifecycle.isGated(busyHarnessId)
      ) {
        const firstHold = !routeState.gatedSessions.has(sessionId)
        routeState.gatedSessions.set(sessionId, busyHarnessId)
        if (firstHold) {
          const harnessName =
            services.agents.catalog.find((definition) => definition.id === busyHarnessId)?.name ??
            busyHarnessId
          await appendAndPublish(services.db, fanout, "session.updateGate.updated", sessionId, {
            harnessId: busyHarnessId,
            harnessName,
            state: "waiting"
          }).catch(() => undefined)
        }
        return
      }
      /* v8 ignore stop */
      const item = await run(services.db.claimPromptQueueItem(sessionId))
      if (item === undefined) {
        await publishPromptQueue(services.db, fanout, sessionId)
        return
      }
      await publishPromptQueue(services.db, fanout, sessionId)
      await runPromptInBackground(
        services,
        fanout,
        serverId,
        sessionId,
        item.id,
        item.text,
        item.attachments
      )
      await run(services.db.completePromptQueueItem(sessionId, item.id))
    }
  } finally {
    routeState.activePromptSessions.delete(sessionId)
    /* v8 ignore next -- defensive: unknown sessions simply skip turn accounting. */
    if (busyHarnessId !== undefined) services.lifecycle?.notifyTurnEnded(busyHarnessId)
  }
}

const runPromptInBackground = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  sessionId: string,
  queueItemId: string,
  text: string,
  attachments?: ReadonlyArray<AttachmentRef>
): Promise<void> => {
  try {
    const refs = attachments ?? []
    await materializeRuntimeEvent(
      services.db,
      fanout,
      serverId,
      {
        kind: "session.output",
        subjectId: sessionId,
        payload: {
          role: "user",
          messageId: queueItemId,
          text,
          ...(refs.length === 0 ? {} : { attachments: refs })
        }
      },
      sessionId
    )
    const agentSession = await ensureAgentSessionFor(services, fanout, serverId, sessionId)
    // Session output, turn lifecycle, and the final stopReason all flow
    // through the standing sink registered at session create/load time.
    const input =
      refs.length === 0
        ? text
        : { attachments: await resolvePromptAttachments(services, refs), text }
    await run(services.agents.prompt(agentSession.sessionId, input))
  } catch (cause) {
    if (isAuthenticationFailure(cause)) {
      const session = await run(services.db.getSessionSummary(sessionId))
      /* v8 ignore next -- auth failures on pinned and legacy sessions are integration-tested. */
      if (session.harnessAccountId !== undefined) {
        await services.auth?.markAccountExpired(session.harnessAccountId, failureMessage(cause))
      }
      await appendAndPublish(services.db, fanout, "session.authRequired", sessionId, {
        detail: failureMessage(cause),
        serverId
      })
    }
    await appendAndPublish(services.db, fanout, "session.error", sessionId, {
      message: failureMessage(cause),
      serverId
    })
  }
}

const sessionHistoryEventsWithSetup = async (
  db: CodevisorDatabaseService,
  serverId: string,
  sessionId: string
): Promise<ReadonlyArray<EventEnvelope>> => {
  const sessionEvents = await run(db.listSubjectEvents(sessionId))
  if (sessionEvents.some((event) => event.kind === "worktree.setup")) {
    return sessionEvents
  }
  const session = await run(db.getSessionSummary(sessionId))
  const worktreeName = session.worktreeName
  if (worktreeName === undefined) {
    return sessionEvents
  }
  const worktree = (await run(db.listWorktrees(session.projectId))).find(
    (candidate) => candidate.serverId === serverId && candidate.name === worktreeName
  )
  if (worktree === undefined) {
    return sessionEvents
  }
  const setupEvents = await run(db.listSubjectEvents(worktree.id))
  return [...sessionEvents, ...setupEvents].sort((left, right) => left.id - right.id)
}

const ensureAgentSessionFor = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  sessionId: string
): Promise<AgentSessionMetadata> => {
  const session = await run(services.db.getSessionSummary(sessionId))
  const project = await getProjectOrFail(services.db, session.projectId)
  const cwd = await resolveSessionCwdOrFail(services, serverId, project, session.worktreeName)
  const accountContext =
    session.harnessAccountId === undefined
      ? await services.auth?.activeAccountContext(session.harnessId)
      : await services.auth?.accountContext(session.harnessAccountId)
  /* v8 ignore next -- authenticated and blocked session-resume paths are integration-tested. */
  if (services.auth !== undefined && accountContext === undefined) {
    throw new HttpFailure(409, "Select a signed-in harness account before continuing this session")
  }
  if (session.harnessAccountId === undefined && accountContext !== undefined) {
    await run(services.db.bindSessionHarnessAccount(session.id, accountContext.id))
  }
  if (session.agentSessionId === "") {
    const sink = sessionEventSink(services, fanout, serverId, sessionId)
    const toolGateway = await services.mcp?.issueGateway(session.id, session.projectId, sink)
    const agentSessionId = await run(
      services.agents.createAgentSession(session.harnessId, cwd, sink, accountContext, toolGateway)
    )
    const updatedSession = await run(services.db.updateSession(sessionId, { agentSessionId }))
    await appendAndPublish(
      services.db,
      fanout,
      "session.updated",
      updatedSession.id,
      updatedSession
    )
    const metadata = await run(
      services.agents.loadAgentSession(
        session.harnessId,
        agentSessionId,
        cwd,
        sink,
        accountContext,
        toolGateway
      )
    )
    return restoreSessionConfigSelections(services, sessionId, metadata)
  }
  const agentSessionId = session.agentSessionId ?? sessionId
  const sink = sessionEventSink(services, fanout, serverId, sessionId)
  const toolGateway = await services.mcp?.issueGateway(session.id, session.projectId, sink)
  const metadata = await run(
    services.agents.loadAgentSession(
      session.harnessId,
      agentSessionId,
      cwd,
      sink,
      accountContext,
      toolGateway
    )
  )
  return restoreSessionConfigSelections(services, sessionId, metadata)
}

const selectableValues = (option: SessionConfigOption): ReadonlySet<string> =>
  new Set(
    option.options.flatMap((entry) =>
      "value" in entry ? [entry.value] : entry.options.map((nested) => nested.value)
    )
  )

const configSelectionsFromOptions = (
  options: ReadonlyArray<SessionConfigOption>
): Readonly<Record<string, string>> =>
  Object.fromEntries(options.map((option) => [option.id, option.currentValue]))

const configRestorePriority = (option: SessionConfigOption | undefined): number => {
  if (option?.category === "model" || option?.id === "model") return 0
  if (option?.category === "thought_level") return 1
  if (option?.category === "speed" || option?.id === "speed") return 2
  return 3
}

/// Rehydrates durable per-chat picker values after the provider has resumed
/// its native thread. Model goes first because it can replace the available
/// reasoning and speed lists. Every later value is validated against the
/// latest options returned by the provider; removed values fall through to
/// the provider's current default and the resolved snapshot replaces them.
const restoreSessionConfigSelections = async (
  services: CodevisorServerServices,
  sessionId: string,
  metadata: AgentSessionMetadata
): Promise<AgentSessionMetadata> => {
  const saved = await run(services.db.getSessionConfigSelections(sessionId))
  let configOptions = metadata.configOptions
  const ordered = Object.entries(saved).sort(([leftId], [rightId]) => {
    const left = configOptions.find((option) => option.id === leftId)
    const right = configOptions.find((option) => option.id === rightId)
    const difference = configRestorePriority(left) - configRestorePriority(right)
    return difference === 0 ? leftId.localeCompare(rightId) : difference
  })
  for (const [configId, value] of ordered) {
    const option = configOptions.find((candidate) => candidate.id === configId)
    if (
      option === undefined ||
      option.currentValue === value ||
      !selectableValues(option).has(value)
    ) {
      continue
    }
    try {
      configOptions = await run(
        services.agents.setConfigOption(metadata.sessionId, configId, value)
      )
    } catch {
      // A harness can reject a value between advertising it and applying it.
      // Session open must still succeed; its current value becomes the durable
      // fallback below.
    }
  }
  await run(
    services.db.replaceSessionConfigSelections(
      sessionId,
      configSelectionsFromOptions(configOptions)
    )
  )
  return { ...metadata, configOptions }
}

const materializeRuntimeEvent = async (
  db: CodevisorDatabaseService,
  fanout: EventFanout,
  serverId: string,
  event: RuntimeEvent,
  subjectId: string
): Promise<void> => {
  const payload = objectPayload(event.payload)
  const harnessTitle =
    event.kind === "session.updated" &&
    payload.sessionUpdate === "session_info_update" &&
    typeof payload.title === "string"
      ? payload.title.trim()
      : undefined
  if (harnessTitle !== undefined && harnessTitle.length > 0) {
    const updated = await run(db.updateSessionTitleFromHarness(subjectId, harnessTitle))
    if (updated !== undefined) {
      await appendAndPublish(db, fanout, "session.updated", subjectId, updated)
    }
    return
  }
  // appendEvent atomically persists the session event and updates the
  // canonical semantic chat rows. There is deliberately no second legacy
  // conversation write here: a crash can no longer split the two stores.
  await appendAndPublish(db, fanout, event.kind, subjectId, {
    ...payload,
    serverId
  })
}

const writeNoContent = (response: ServerResponse): void => {
  writeJson(response, 204, {})
}

const conversationRoles = new Set(["user", "assistant", "system"])

const isConversationPayload = (
  payload: unknown
): payload is {
  readonly role: "user" | "assistant" | "system"
  readonly text: string
  readonly messageId?: string
  readonly attachments?: ReadonlyArray<AttachmentRef>
} =>
  typeof payload === "object" &&
  payload !== null &&
  "role" in payload &&
  "text" in payload &&
  conversationRoles.has(String(payload.role)) &&
  typeof payload.text === "string" &&
  (!("messageId" in payload) || typeof payload.messageId === "string") &&
  (!("attachments" in payload) || Array.isArray(payload.attachments))

const conversationPayload = (
  payload: unknown
):
  | {
      readonly role: "user" | "assistant" | "system"
      readonly text: string
      readonly messageId?: string
      readonly attachments?: ReadonlyArray<AttachmentRef>
    }
  | undefined => {
  if (isConversationPayload(payload)) {
    return payload
  }
  if (!isRecord(payload) || typeof payload.sessionUpdate !== "string") {
    return undefined
  }
  // Subagent-attributed chunks stay out of the text conversation snapshot;
  // clients rebuild nested subagent transcripts from the raw event log.
  if (typeof payload.parentToolCallId === "string") {
    return undefined
  }
  const text = textFromRawContent(payload.content)
  if (text === undefined) {
    return undefined
  }
  switch (payload.sessionUpdate) {
    case "user_message_chunk":
      return {
        role: "user",
        text,
        ...(typeof payload.messageId === "string" ? { messageId: payload.messageId } : {})
      }
    case "agent_message_chunk":
      return {
        role: "assistant",
        text,
        ...(typeof payload.messageId === "string" ? { messageId: payload.messageId } : {})
      }
    default:
      return undefined
  }
}

const isUserRuntimeEvent = (event: RuntimeEvent): boolean =>
  conversationPayload(event.payload)?.role === "user"

const textFromRawContent = (content: unknown): string | undefined =>
  isRecord(content) && content.type === "text" && typeof content.text === "string"
    ? content.text
    : undefined

const objectPayload = (payload: unknown): Record<string, unknown> =>
  isRecord(payload) ? payload : { value: payload }

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value)

const isAuthenticationFailure = (cause: unknown): boolean => {
  const message = failureMessage(cause).toLowerCase()
  return (
    message.includes("authentication") ||
    message.includes("unauthorized") ||
    message.includes("not logged in") ||
    message.includes("sign-in") ||
    message.includes("sign in") ||
    message.includes("token expired")
  )
}
