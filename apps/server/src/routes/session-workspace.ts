import type { AgentSessionMetadata } from "@codevisor/agent-runtime"
import { randomUUID } from "node:crypto"
import type {
  CreateSessionRequest,
  UpdateSessionRequest,
  EventEnvelope,
  Project,
  SessionConfigOption,
  SessionSummary
} from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"
import {
  appendAndPublish,
  archiveSessionRuntime,
  archiveSessionWorktree,
  assertLocationFolderExists,
  existingDirectory,
  getProjectOrFail,
  HttpFailure,
  localLocationOrFail,
  restoreSessionWorktree,
  run,
  type CodevisorServerConfig,
  type CodevisorServerServices,
  type EventFanout,
  type RouteState
} from "../server-context.js"
import { sessionEventSink } from "./session-events.js"

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
  const session = await run(
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
  // Session membership predates explicit workspace panes. Route every create
  // through the compatibility bridge so old clients still materialize the
  // canonical shared chat pane.
  if (payload.workspaceId !== undefined) {
    await run(services.db.setSessionWorkspace(session.id, payload.workspaceId))
    return run(services.db.getSessionSummary(session.id))
  }
  return session
}

/// Create-or-return for sessions: the existing-row and in-flight-create
/// checks (concurrent POSTs for the same client-supplied id must not spawn
/// two agent sessions) shared by POST /v1/sessions and the combined
/// /open route.
export const createSessionIfMissing = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  routeState: RouteState,
  config: CodevisorServerConfig,
  rawPayload: CreateSessionRequest,
  publishCreated = true
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
  if (publishCreated) {
    await appendAndPublish(services.db, fanout, "session.created", session.id, session)
  }
  return { session, created: true }
}

/// The full PATCH side-effect set — archive teardown and the
/// updated/archived event fanout — shared by PATCH /v1/sessions/:id and the
/// combined /open route so opening a chat behaves exactly like the discrete
/// update it replaced.
export const applySessionUpdate = async (
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

/// Derives the directory a session runs in: the project's folder on this
/// server, or its worktree at ~/codevisor/{projectId}/{worktreeName}. The result
/// must stay deterministic per session so the agent-runtime session cache hits.
export const resolveSessionCwdOrFail = async (
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

export const findSession = async (
  db: CodevisorDatabaseService,
  id: string
): Promise<SessionSummary | undefined> => {
  try {
    return await run(db.getSessionSummary(id))
  } catch {
    return undefined
  }
}

export const sessionHistoryEventsWithSetup = async (
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

export const ensureAgentSessionFor = async (
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

export const configSelectionsFromOptions = (
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
