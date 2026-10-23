import {
  AgentState as AgentStateSchema,
  WaitForAgentsRequest,
  type AgentArchiveResult,
  type AgentState,
  type AgentSummary,
  type Project,
  type SessionSummary,
  type WaitedAgent
} from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"
import { Schema } from "effect"

import { archiveWorkspaceAndWait } from "../archive-jobs.js"
import { appendAndPublish, HttpFailure, readSchema, run, writeJson } from "../server-context.js"
import { captureWorkspaceRuntime } from "../server-workspace-effects.js"
import { agentState } from "./agent-state.js"
import { assertNotOwnedByBot } from "./bot-guards.js"
import { matchesLabelFilters } from "./label-filters.js"
import type { RouteContext } from "./route-context.js"
import { waitUntilSettled } from "./session-wait.js"

export const listAgents = async ({ services, response, url }: RouteContext): Promise<boolean> => {
  const filters = listFilters(url, await run(services.db.listProjects))
  const sessions = (await run(services.db.listSessions)).filter((session) =>
    listedSession(session, filters, url)
  )
  const items = await Promise.all(sessions.map((session) => agentSummary(services.db, session)))
  writeJson(response, 200, {
    items: items.filter((item) => filters.state === undefined || item.state === filters.state)
  })
  return true
}

export const waitForAgents = async ({
  services,
  fanout,
  request,
  response
}: RouteContext): Promise<boolean> => {
  const payload = await readSchema(request, WaitForAgentsRequest)
  const until = new Set(payload.until ?? defaultWaitUntil)
  const abort = new AbortController()
  response.once("close", () => abort.abort())
  const waited = await waitUntilSettled(services.db, fanout, {
    ids: payload.agentIds,
    timeoutMs: payload.timeoutMs,
    signal: abort.signal,
    settled: (session) => settledIn(services.db, session, until),
    describe: (session) => waitedAgent(services.db, session)
  })
  writeJson(response, 200, waited)
  return true
}

export const archiveAgent = async (
  { services, fanout, config, routeState, response }: RouteContext,
  agentId: string
): Promise<boolean> => {
  const session = await run(services.db.getSessionSummary(agentId))
  const workspaceId = session.workspaceId
  if (workspaceId === undefined) throw new HttpFailure(422, `Agent ${agentId} has no workspace`)
  await assertNotOwnedByBot(services, { workspaceId }, "archive this workspace")

  const workspace = await run(services.db.updateWorkspace(workspaceId, { isArchived: true }))
  await appendAndPublish(services.db, fanout, "workspace.updated", workspace.id, workspace)
  const runtime = await captureWorkspaceRuntime(services, routeState, workspace)
  const keptArtifacts = await archiveWorkspaceAndWait(services, fanout, config, workspace, runtime)
  const result: AgentArchiveResult = {
    agentId: session.id,
    workspaceId,
    archived: true,
    keptArtifacts
  }
  writeJson(response, 200, result)
  return true
}

const defaultWaitUntil: ReadonlyArray<AgentState> = ["idle", "waitingForUser", "errored"]

interface ListFilters {
  readonly state: AgentState | undefined
  readonly projectId: string | undefined
  readonly parentAgentId: string | undefined
}

const isAgentState = Schema.is(AgentStateSchema)

const listFilters = (url: URL, projects: ReadonlyArray<Project>): ListFilters => {
  const state = url.searchParams.get("state") ?? undefined
  if (state !== undefined && !isAgentState(state))
    throw new HttpFailure(400, `Unknown state: ${state}`)
  return {
    state,
    projectId: projectIdNamed(url.searchParams.get("project") ?? undefined, projects),
    parentAgentId: url.searchParams.get("parentAgentId")?.toLowerCase()
  }
}

const projectIdNamed = (
  project: string | undefined,
  projects: ReadonlyArray<Project>
): string | undefined => {
  if (project === undefined) return undefined
  const wanted = project.toLowerCase()
  const found = projects.find(
    (candidate) => candidate.id.toLowerCase() === wanted || candidate.name.toLowerCase() === wanted
  )
  return (found?.id ?? wanted).toLowerCase()
}

const listedSession = (session: SessionSummary, filters: ListFilters, url: URL): boolean =>
  matchesOptional(session.projectId, filters.projectId) &&
  matchesOptional(session.parentSessionId, filters.parentAgentId) &&
  matchesLabelFilters(session.labels, url)

const matchesOptional = (value: string | undefined, wanted: string | undefined): boolean =>
  wanted === undefined || value?.toLowerCase() === wanted

const agentSummary = async (
  db: CodevisorDatabaseService,
  session: SessionSummary
): Promise<AgentSummary> => ({
  agentId: session.id,
  title: session.title,
  state: await currentState(db, session),
  projectId: session.projectId,
  harness: session.harnessId,
  ...(session.workspaceId === undefined ? {} : { workspaceId: session.workspaceId }),
  ...(session.worktreeName === undefined ? {} : { worktreeName: session.worktreeName }),
  ...(session.labels === undefined ? {} : { labels: session.labels }),
  ...(session.parentSessionId === undefined ? {} : { parentAgentId: session.parentSessionId }),
  ...(session.updatedAt === undefined ? {} : { updatedAt: session.updatedAt })
})

const currentState = async (
  db: CodevisorDatabaseService,
  session: SessionSummary
): Promise<AgentState> =>
  agentState(session, await run(db.getTranscriptPage(session.id, undefined, 1)))

const settledIn = async (
  db: CodevisorDatabaseService,
  session: SessionSummary,
  until: ReadonlySet<AgentState>
): Promise<boolean> => {
  const state = await currentState(db, session)
  if (!until.has(state)) return false
  return state !== "idle" || !(await hasQueuedPrompts(db, session.id))
}

const hasQueuedPrompts = async (db: CodevisorDatabaseService, agentId: string): Promise<boolean> =>
  (await run(db.listPromptQueue(agentId))).length > 0 ||
  (await run(db.listProcessingPromptQueue(agentId))).length > 0

const waitedAgent = async (
  db: CodevisorDatabaseService,
  session: SessionSummary
): Promise<WaitedAgent> => {
  const page = await run(db.getTranscriptPage(session.id, undefined, 1))
  return {
    agentId: session.id,
    state: agentState(session, page),
    ...(page.pendingQuestion === undefined ? {} : { pendingQuestion: page.pendingQuestion })
  }
}
