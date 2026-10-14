import { randomUUID } from "node:crypto"

import {
  placeConfigValue,
  type AgentSessionMetadata,
  type HarnessAccountContext
} from "@codevisor/agent-runtime"
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
import { publishSessionConfigOptions, publishSessionSelections } from "./session-config-publish.js"
import { resolveSessionAccount, startSessionAgent, withStartPicks } from "./session-creation.js"
import { sessionEventSink } from "./session-events.js"
import { withSessionMutation } from "./session-operations.js"
import { publishSessionSkills } from "./session-skills.js"

const createServerSession = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  request: CreateSessionRequest,
  project: Project
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

export const createSessionIfMissing = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  routeState: RouteState,
  config: CodevisorServerConfig,
  rawPayload: CreateSessionRequest,
  publishCreated = true
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
    const session = await createServerSession(services, fanout, config.id, payload, project)
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
  if (session.agentSessionId === "") {
    const sink = sessionEventSink(services, fanout, serverId, sessionId)
    const toolGateway = await services.mcp?.issueGateway(session.id, session.projectId, sink)
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
    const metadata = await run(
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
    if (await sessionIsArchived(services, await run(services.db.getSessionSummary(sessionId)))) {
      await run(services.agents.closeAgentSession(agentSessionId))
      throw new HttpFailure(409, "Workspace was archived while starting its agent")
    }
    await publishSessionSkills(services, fanout, serverId, sessionId, metadata)
    return restoreSessionConfigSelections(services, fanout, serverId, sessionId, metadata)
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
      toolGateway,
      startOptions
    )
  )
  if (await sessionIsArchived(services, await run(services.db.getSessionSummary(sessionId)))) {
    await run(services.agents.closeAgentSession(agentSessionId))
    throw new HttpFailure(409, "Workspace was archived while starting its agent")
  }
  await publishSessionSkills(services, fanout, serverId, sessionId, metadata)
  return restoreSessionConfigSelections(services, fanout, serverId, sessionId, metadata)
}

export const configRestorePriority = (option: SessionConfigOption | undefined): number => {
  if (option?.category === "model" || option?.id === "model") return 0
  if (option?.category === "thought_level") return 1
  if (option?.category === "speed" || option?.id === "speed") return 2
  return 3
}

const restoreSessionConfigSelections = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  sessionId: string,
  metadata: AgentSessionMetadata
): Promise<AgentSessionMetadata> => {
  if (metadata.configOptions.length === 0) {
    await run(services.db.saveSessionRuntimeState(sessionId, metadata))
    return metadata
  }
  const summary = await run(services.db.getSessionSummary(sessionId))
  const saved = summary.configSelections ?? {}
  const previouslyUnavailable = summary.unavailableConfigSelections ?? {}
  const reconcile = (option: SessionConfigOption, value: string): string | undefined =>
    services.agents.reconcileConfigValue(summary.harnessId, option, value)
  let configOptions = metadata.configOptions
  const migrated: Record<string, string> = {}
  const unavailable: Record<string, string> = Object.fromEntries(
    Object.entries(previouslyUnavailable).filter(([configId, value]) => saved[configId] === value)
  )
  const ordered = Object.entries(saved).toSorted(([leftId], [rightId]) => {
    const left = configOptions.find((option) => option.id === leftId)
    const right = configOptions.find((option) => option.id === rightId)
    const difference = configRestorePriority(left) - configRestorePriority(right)
    return difference === 0 ? leftId.localeCompare(rightId) : difference
  })
  for (const [configId, value] of ordered) {
    const option = configOptions.find((candidate) => candidate.id === configId)
    if (option === undefined) continue
    const restored = placeConfigValue(option, value, reconcile)
    if (restored === undefined) {
      console.error(
        `[session-config] ${sessionId}: saved ${configId}=${value} is no longer offered; keeping it as unavailable`
      )
      unavailable[configId] = value
      continue
    }
    delete unavailable[configId]
    if (restored !== value) migrated[configId] = restored
    if (option.currentValue === restored) continue
    try {
      configOptions = await run(
        services.agents.setConfigOption(metadata.sessionId, configId, restored)
      )
    } catch (error) {
      console.error(
        `[session-config] ${sessionId}: could not restore ${configId}=${restored}: ${String(error)}`
      )
    }
  }
  const selections = { ...saved, ...migrated }
  if (!sameSelections(selections, saved) || !sameSelections(unavailable, previouslyUnavailable)) {
    await run(services.db.replaceSessionConfigSelections(sessionId, selections, unavailable))
    await publishSessionSelections(services, fanout, sessionId)
  }
  await publishSessionConfigOptions(services, fanout, serverId, sessionId, configOptions)
  const current = { ...metadata, configOptions }
  await run(services.db.saveSessionRuntimeState(sessionId, current))
  return current
}

const sameSelections = (
  left: Readonly<Record<string, string>>,
  right: Readonly<Record<string, string>>
): boolean =>
  Object.keys(left).length === Object.keys(right).length &&
  Object.entries(left).every(([key, value]) => right[key] === value)
