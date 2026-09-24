import { randomUUID } from "node:crypto"

import type { AgentSessionMetadata, HarnessAccountContext } from "@codevisor/agent-runtime"
import type {
  CreateSessionRequest,
  UpdateSessionRequest,
  Project,
  SessionConfigOption,
  SessionSummary
} from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"

import {
  appendAndPublish,
  assertLocationFolderExists,
  existingDirectory,
  getProjectOrFail,
  HttpFailure,
  localLocationOrFail,
  sessionIsArchived,
  run,
  type CodevisorServerConfig,
  type CodevisorServerServices,
  type EventFanout,
  type RouteState
} from "../server-context.js"
import { resolveSessionAccount, startSessionAgent } from "./session-creation.js"
import { sessionEventSink } from "./session-events.js"

const createServerSession = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  payload: CreateSessionRequest,
  project: Project
): Promise<SessionSummary> => {
  const cwd = await resolveSessionCwdOrFail(services, serverId, project, payload.worktreeName)
  const { accountContext, harnessAccountId } = await resolveSessionAccount(services, payload)
  const workspaceExisted = await assertWorkspaceProject(services, payload.workspaceId, project)
  const sessionId = payload.id ?? randomUUID()
  const agentSessionId = await startSessionAgent(
    services,
    fanout,
    serverId,
    sessionId,
    project,
    payload,
    cwd,
    accountContext
  )
  const sessionPayload = {
    ...payload,
    id: sessionId,
    // Use the resolved project's canonical id (the client may have sent a
    // different-cased UUID) so the session's foreign key matches the row.
    projectId: project.id,
    ...(harnessAccountId === undefined ? {} : { harnessAccountId }),
    agentSessionId
  }
  if (payload.workspaceId === undefined) {
    return run(services.db.createSession(sessionPayload))
  }
  // A chat born into a workspace commits with the workspace row (created here
  // when the client has not uploaded it yet) and its chat pane in ONE
  // transaction, so no other client can observe the workspace without its
  // chat. The events below keep clients that predate the navigation journal
  // informed, exactly as the discrete writes used to.
  const created = await run(
    services.db.createWorkspaceWithSession({
      workspace: {
        ...(payload.sidebarOrderHead === undefined
          ? {}
          : { sidebarOrderHead: payload.sidebarOrderHead }),
        id: payload.workspaceId.toLowerCase(),
        projectId: project.id,
        name: payload.worktreeName ?? project.name,
        hasCustomName: false,
        rootDirectory: cwd
      },
      session: { ...sessionPayload, workspaceId: undefined }
    })
  )
  if (!workspaceExisted) {
    await appendAndPublish(
      services.db,
      fanout,
      "workspace.updated",
      created.workspace.id,
      created.workspace
    )
  }
  return created.session
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

/// The full PATCH side-effect set, shared by PATCH /v1/sessions/:id and the
/// combined /open route so opening a chat behaves exactly like the discrete
/// update it replaced.
///
/// Chats carry no archive state: their workspace does, and the worktree is
/// reclaimed when that workspace is archived. Closing a chat is pane removal,
/// which `setSessionWorkspace(id, null)` performs.
export const applySessionUpdate = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  sessionId: string,
  payload: UpdateSessionRequest
): Promise<SessionSummary> => {
  const before = await findSession(services.db, sessionId)
  if (payload.workspaceId !== undefined && before !== undefined) {
    const project = await getProjectOrFail(services.db, payload.projectId ?? before.projectId)
    await ensureSessionWorkspace(
      services,
      fanout,
      payload.workspaceId,
      project,
      payload.worktreeName ?? before.worktreeName ?? project.name,
      before.cwd,
      payload.sidebarOrderHead
    )
  }
  let session = await run(services.db.updateSession(sessionId, payload))
  if (payload.workspaceId !== undefined) {
    await run(services.db.setSessionWorkspace(sessionId, payload.workspaceId))
    session = await run(services.db.getSessionSummary(sessionId))
  }

  await appendAndPublish(services.db, fanout, "session.updated", session.id, session)
  return session
}

/// Whether the workspace already exists, rejecting a cross-project pairing
/// with the same 409 both the discrete and the atomic create paths owe.
const assertWorkspaceProject = async (
  services: CodevisorServerServices,
  workspaceId: string | undefined,
  project: Project
): Promise<boolean> => {
  if (workspaceId === undefined) return false
  const canonical = workspaceId.toLowerCase()
  const existing = (await run(services.db.listWorkspaces)).find(
    (workspace) => workspace.id.toLowerCase() === canonical
  )
  if (existing === undefined) return false
  if (existing.projectId.toLowerCase() !== project.id.toLowerCase()) {
    throw new HttpFailure(
      409,
      `Workspace ${workspaceId} belongs to project ${existing.projectId}, not ${project.id}`
    )
  }
  return true
}

/// Native clients persist pane layout locally, but workspace identity and
/// membership are server-owned. Assigning an EXISTING chat to a workspace the
/// client has not uploaded yet lazily creates the metadata row first. The
/// event lets every other client materialize its own local layout for the
/// shared workspace.
const ensureSessionWorkspace = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  workspaceId: string,
  project: Project,
  workspaceName: string,
  rootDirectory: string | undefined,
  sidebarOrderHead?: string
): Promise<void> => {
  if (await assertWorkspaceProject(services, workspaceId, project)) return
  const canonical = workspaceId.toLowerCase()
  const workspace = await run(
    services.db.upsertWorkspace({
      ...(sidebarOrderHead === undefined ? {} : { sidebarOrderHead }),
      id: canonical,
      projectId: project.id,
      name: workspaceName,
      hasCustomName: false,
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

export const ensureAgentSessionFor = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  sessionId: string
): Promise<AgentSessionMetadata> => {
  let session = await run(services.db.getSessionSummary(sessionId))
  if (await sessionIsArchived(services, session))
    throw new HttpFailure(409, "Restore the workspace before starting its agent")
  const project = await getProjectOrFail(services.db, session.projectId)
  const cwd = await resolveSessionCwdOrFail(services, serverId, project, session.worktreeName)
  let accountContext: HarnessAccountContext | undefined
  if (services.auth === undefined || session.harnessAccountId === undefined) {
    accountContext = await services.auth?.activeAccountContext(session.harnessId)
  } else {
    try {
      accountContext = await services.auth.accountContext(session.harnessAccountId)
    } catch {
      // Policy, not a fallback: a chat follows a working account, preferring
      // its pin. The pinned account is used while it can authenticate; once it
      // is dead (signed out, expired, removed) the session rebinds to the
      // machine's usable active account and the turn continues under it, so a
      // chat never keeps burning a dead account while a working one sits idle.
      // Without a usable active account the turn still fails with 409 below.
      accountContext = await services.auth.activeAccountContext(session.harnessId)
      if (accountContext !== undefined && accountContext.id !== session.harnessAccountId) {
        session = await run(services.db.bindSessionHarnessAccount(session.id, accountContext.id))
        await appendAndPublish(services.db, fanout, "session.updated", session.id, session)
      }
    }
  }
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
    if (await sessionIsArchived(services, await run(services.db.getSessionSummary(sessionId)))) {
      await run(services.agents.closeAgentSession(agentSessionId))
      throw new HttpFailure(409, "Workspace was archived while starting its agent")
    }
    return restoreSessionConfigSelections(services, sessionId, session.harnessId, metadata)
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
  if (await sessionIsArchived(services, await run(services.db.getSessionSummary(sessionId)))) {
    await run(services.agents.closeAgentSession(agentSessionId))
    throw new HttpFailure(409, "Workspace was archived while starting its agent")
  }
  return restoreSessionConfigSelections(services, sessionId, session.harnessId, metadata)
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
  harnessId: string,
  metadata: AgentSessionMetadata
): Promise<AgentSessionMetadata> => {
  // No option list is not an answer: the Claude adapter returns none when its
  // model list loses the startup race, and a snapshot derived from it would
  // wipe the chat's saved model/effort. Leave the saved selections untouched
  // so the next reconnect (or a late config update) can still restore them.
  if (metadata.configOptions.length === 0) {
    await run(services.db.saveSessionRuntimeState(sessionId, metadata))
    return metadata
  }
  const saved = await run(services.db.getSessionConfigSelections(sessionId))
  let configOptions = metadata.configOptions
  let restoreFailed = false
  const ordered = Object.entries(saved).sort(([leftId], [rightId]) => {
    const left = configOptions.find((option) => option.id === leftId)
    const right = configOptions.find((option) => option.id === rightId)
    const difference = configRestorePriority(left) - configRestorePriority(right)
    return difference === 0 ? leftId.localeCompare(rightId) : difference
  })
  for (const [configId, value] of ordered) {
    const option = configOptions.find((candidate) => candidate.id === configId)
    if (option === undefined || option.currentValue === value) continue
    // A saved value the runtime no longer offers verbatim may still name a
    // current entry under a newer id (Claude's Fable id drifts between CLI
    // releases). The provider says which; a value it cannot place is gone
    // and falls through to the runtime's default.
    const restored = selectableValues(option).has(value)
      ? value
      : services.agents.reconcileConfigValue(harnessId, option, value)
    if (restored === undefined || !selectableValues(option).has(restored)) {
      console.error(
        `[session-config] ${sessionId}: saved ${configId}=${value} is no longer offered; using ${option.currentValue}`
      )
      continue
    }
    if (option.currentValue === restored) continue
    try {
      configOptions = await run(
        services.agents.setConfigOption(metadata.sessionId, configId, restored)
      )
    } catch (error) {
      // A harness can reject a value between advertising it and applying it.
      // Session open must still succeed. Keep its current value for this
      // runtime, but retain the user's saved snapshot so the
      // next reconnect can retry instead of turning a transient startup race
      // into a permanent preference change.
      console.error(
        `[session-config] ${sessionId}: could not restore ${configId}=${restored}: ${String(error)}`
      )
      restoreFailed = true
    }
  }
  const resolvedSelections = configSelectionsFromOptions(configOptions)
  await run(
    services.db.replaceSessionConfigSelections(
      sessionId,
      restoreFailed ? { ...resolvedSelections, ...saved } : resolvedSelections
    )
  )
  const current = { ...metadata, configOptions }
  await run(services.db.saveSessionRuntimeState(sessionId, current))
  return current
}
