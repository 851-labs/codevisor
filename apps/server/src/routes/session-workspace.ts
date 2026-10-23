import { randomUUID } from "node:crypto"

import type { AgentSessionMetadata, HarnessAccountContext } from "@codevisor/agent-runtime"
import type {
  CreateSessionRequest,
  UpdateSessionRequest,
  Project,
  SessionSummary
} from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"

import type { RemoteBotLink } from "../infra/fleet-tickets.js"
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
import { botForParentSession } from "./bot-guards.js"
import { restoreSessionConfigSelections } from "./session-config-restore.js"
import { resolveSessionAccount, startSessionAgent, withStartPicks } from "./session-creation.js"
import { sessionEventSink } from "./session-events.js"
import { withSessionMutation } from "./session-operations.js"
import { publishSessionSkills } from "./session-skills.js"

const createServerSession = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  request: CreateSessionRequest,
  project: Project,
  fleetBot: RemoteBotLink | undefined
): Promise<SessionSummary> => {
  const payload = await withStartPicks(services, request)
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
    projectId: project.id,
    ...(harnessAccountId === undefined ? {} : { harnessAccountId }),
    agentSessionId
  }
  if (payload.workspaceId === undefined) {
    return run(services.db.createSession(sessionPayload))
  }
  const created = await run(
    services.db.createWorkspaceWithSession({
      workspace: {
        ...workspaceOrder(payload),
        ...(await botForParentSession(services, serverId, payload.parentSessionId, fleetBot)),
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

export const createSessionIfMissing = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  routeState: RouteState,
  config: CodevisorServerConfig,
  rawPayload: CreateSessionRequest,
  publishCreated = true,
  fleetBot?: RemoteBotLink
): Promise<{ readonly session: SessionSummary; readonly created: boolean }> => {
  const payload: CreateSessionRequest =
    rawPayload.id === undefined ? rawPayload : { ...rawPayload, id: rawPayload.id.toLowerCase() }
  if (payload.id !== undefined) {
    const pending = routeState.pendingSessionCreates.get(payload.id)
    if (pending !== undefined) {
      return { session: await pending, created: false }
    }
  }
  let created = false
  const create = (async () => {
    if (payload.id !== undefined) {
      const existing = await findSession(services.db, payload.id)
      if (existing !== undefined) return existing
    }
    const project = await getProjectOrFail(services.db, payload.projectId)
    const session = await createServerSession(
      services,
      fanout,
      config.id,
      payload,
      project,
      fleetBot
    )
    created = true
    if (publishCreated) {
      await appendAndPublish(services.db, fanout, "session.created", session.id, session)
    }
    return session
  })()
  if (payload.id !== undefined) {
    routeState.pendingSessionCreates.set(payload.id, create)
  }
  const session = await create.finally(() => {
    if (payload.id !== undefined && routeState.pendingSessionCreates.get(payload.id) === create) {
      routeState.pendingSessionCreates.delete(payload.id)
    }
  })
  return { session, created }
}

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
      workspaceOrder(payload)
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

type WorkspaceOrder = Pick<UpdateSessionRequest, "sidebarOrderHead" | "sidebarPosition">

const workspaceOrder = (payload: WorkspaceOrder): WorkspaceOrder => ({
  ...(payload.sidebarOrderHead === undefined ? {} : { sidebarOrderHead: payload.sidebarOrderHead }),
  ...(payload.sidebarPosition === undefined ? {} : { sidebarPosition: payload.sidebarPosition })
})

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

const ensureSessionWorkspace = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  workspaceId: string,
  project: Project,
  workspaceName: string,
  rootDirectory: string | undefined,
  order: WorkspaceOrder
): Promise<void> => {
  if (await assertWorkspaceProject(services, workspaceId, project)) return
  const canonical = workspaceId.toLowerCase()
  const workspace = await run(
    services.db.upsertWorkspace({
      ...order,
      id: canonical,
      projectId: project.id,
      name: workspaceName,
      hasCustomName: false,
      /* v8 ignore next */
      ...(rootDirectory === undefined ? {} : { rootDirectory })
    })
  )
  await appendAndPublish(services.db, fanout, "workspace.updated", workspace.id, workspace)
}

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
): Promise<AgentSessionMetadata> =>
  withSessionMutation(services, sessionId, () =>
    loadAgentSessionFor(services, fanout, serverId, sessionId)
  )

export const loadAgentSessionFor = async (
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
      accountContext = await services.auth.activeAccountContext(session.harnessId)
      if (accountContext !== undefined && accountContext.id !== session.harnessAccountId) {
        session = await run(services.db.bindSessionHarnessAccount(session.id, accountContext.id))
        await appendAndPublish(services.db, fanout, "session.updated", session.id, session)
      }
    }
  }
  /* v8 ignore next */
  if (services.auth !== undefined && accountContext === undefined) {
    throw new HttpFailure(409, "Select a signed-in harness account before continuing this session")
  }
  if (session.harnessAccountId === undefined && accountContext !== undefined) {
    await run(services.db.bindSessionHarnessAccount(session.id, accountContext.id))
  }
  const startOptions = { configSelections: session.configSelections ?? {} }
  const sink = sessionEventSink(services, fanout, serverId, sessionId)
  const toolGateway = await services.mcp?.issueGateway(session.id, session.projectId, sink)
  const load = (agentSessionId: string) =>
    run(
      services.agents.loadAgentSession(
        session.harnessId,
        agentSessionId,
        cwd,
        sink,
        accountContext,
        toolGateway,
        startOptions
      )
    )
  const startFresh = async () => {
    const agentSessionId = await run(
      services.agents.createAgentSession(
        session.harnessId,
        cwd,
        sink,
        accountContext,
        toolGateway,
        startOptions
      )
    )
    const updatedSession = await run(services.db.updateSession(sessionId, { agentSessionId }))
    await appendAndPublish(
      services.db,
      fanout,
      "session.updated",
      updatedSession.id,
      updatedSession
    )
    return { agentSessionId, metadata: await load(agentSessionId) }
  }
  const resumeOrStartFresh = async () => {
    const resumedId = session.agentSessionId ?? sessionId
    try {
      return { agentSessionId: resumedId, metadata: await load(resumedId) }
    } catch (cause) {
      if (session.origin !== "codevisor" || !(await hasNoAgentReplyToLose(services, sessionId))) {
        throw cause
      }
      return startFresh()
    }
  }
  let started: Awaited<ReturnType<typeof startFresh>>
  if (session.agentSessionId === "") started = await startFresh()
  else started = await resumeOrStartFresh()
  const { agentSessionId, metadata } = started
  if (await sessionIsArchived(services, await run(services.db.getSessionSummary(sessionId)))) {
    await run(services.agents.closeAgentSession(agentSessionId))
    throw new HttpFailure(409, "Workspace was archived while starting its agent")
  }
  await publishSessionSkills(services, fanout, serverId, sessionId, metadata)
  return restoreSessionConfigSelections(services, fanout, serverId, sessionId, metadata)
}

const hasNoAgentReplyToLose = async (
  services: CodevisorServerServices,
  sessionId: string
): Promise<boolean> => {
  const detail = await run(services.db.getSessionDetail(sessionId))
  return (
    !detail.hasMore &&
    detail.conversation.every((item) => item.role === "user" || item.text.trim() === "")
  )
}
