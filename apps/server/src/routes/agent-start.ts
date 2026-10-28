import { randomUUID } from "node:crypto"

import { withRunningThoughtLevel } from "@codevisor/agent-runtime"
import {
  DEFAULT_SUBSCRIPTION_EVENTS,
  StartAgentRequest,
  type Project,
  type SessionSummary,
  type StartedAgent
} from "@codevisor/api"

import { HttpFailure, readSchema, run, writeJson } from "../server-context.js"
import { verifiedRemoteParent } from "./fleet-calls.js"
import { allocateProjectWorktree } from "./project-worktree-create.js"
import {
  defaultPromptDelivery,
  deliverQueuedPrompt,
  refuseWhileUpdating
} from "./prompt-delivery.js"
import { drainPromptQueue } from "./prompt-queue.js"
import type { RouteContext } from "./route-context.js"
import { createSessionIfMissing, findSession } from "./session-workspace.js"
import { deleteServerSession } from "./sessions.js"

export const AGENT_START_CLEANUP_MS = 30_000

export const startAgent = async (route: RouteContext): Promise<boolean> => {
  const request = await readSchema(route.request, StartAgentRequest)
  const caller = await callerOf(route, request)
  const projectId = await projectIdFor(route, request.project, caller)
  const harnessId = harnessFor(request, caller)

  const created: Array<() => Promise<unknown>> = []
  try {
    const started = await startPlanned(route, request, { projectId, harnessId, caller }, created)
    writeJson(route.response, 201, started)
    return true
  } catch (cause) {
    throw await rolledBack(cause, created)
  }
}

interface AgentCaller {
  readonly sessionId: string | undefined
  readonly parentKey: string | undefined
  readonly projectId: string | undefined
  readonly workspaceId: string | undefined
  readonly worktreeName: string | undefined
  readonly harnessId: string | undefined
  readonly configSelections: Readonly<Record<string, string>> | undefined
}

interface AgentPlan {
  readonly projectId: string
  readonly harnessId: string
  readonly caller: AgentCaller
}

interface Placement {
  readonly workspaceId: string
  readonly worktreeName?: string
}

const startPlanned = async (
  route: RouteContext,
  request: StartAgentRequest,
  plan: AgentPlan,
  created: Array<() => Promise<unknown>>
): Promise<StartedAgent> => {
  const { services, fanout, routeState, config } = route
  const remoteParent = verifiedRemoteParent(services, route.request, plan.caller.parentKey)
  const placement = await placementFor(route, request, plan, created)
  const { session } = await createSessionIfMissing(
    services,
    fanout,
    routeState,
    config,
    {
      projectId: plan.projectId,
      harnessId: plan.harnessId,
      title: request.title,
      ...placement,
      ...optionalFields(request, plan)
    },
    true,
    remoteParent
  )
  created.push(() => deleteServerSession(services, fanout, session.id))

  const subscribed = await subscribeCaller(route, plan.caller, session.id)
  const delivered = await sendFirstPrompt(route, session.id, request.prompt)
  return { ...startedAgent(session, placement), delivered, subscribed }
}

const callerOf = async (route: RouteContext, request: StartAgentRequest): Promise<AgentCaller> => {
  if (request.callerAgentId === undefined) return remoteCaller(request)
  const session = await findSession(route.services.db, request.callerAgentId)
  if (session === undefined) throw new HttpFailure(422, `Unknown caller: ${request.callerAgentId}`)
  const runtime = await run(route.services.db.getSessionRuntimeState(session.id))
  return localCaller(session, runtime)
}

const remoteCaller = ({ callerDefaults, remoteParentAgentId }: StartAgentRequest): AgentCaller => ({
  sessionId: undefined,
  parentKey: remoteParentAgentId,
  projectId: undefined,
  workspaceId: undefined,
  worktreeName: undefined,
  harnessId: callerDefaults?.harness,
  configSelections: callerDefaults?.configSelections
})

const localCaller = (session: SessionSummary, runtime: unknown): AgentCaller => ({
  sessionId: session.id,
  parentKey: session.id,
  projectId: session.projectId,
  workspaceId: session.workspaceId,
  worktreeName: session.worktreeName,
  harnessId: session.harnessId,
  configSelections: withRunningThoughtLevel(session.configSelections, runtime)
})

const projectIdFor = async (
  route: RouteContext,
  project: string | undefined,
  caller: AgentCaller
): Promise<string> => {
  if (project === undefined && caller.projectId !== undefined) return caller.projectId
  const projects = await run(route.services.db.listProjects)
  const wanted = project?.toLowerCase()
  const found = projects.find((candidate) => matchesProject(candidate, wanted))
  if (found !== undefined) return found.id
  throw new HttpFailure(422, projectHint(project, projects))
}

const matchesProject = (project: Project, wanted: string | undefined): boolean =>
  project.id.toLowerCase() === wanted || project.name.toLowerCase() === wanted

const projectHint = (project: string | undefined, projects: ReadonlyArray<Project>): string => {
  const names = projects.map((candidate) => `${candidate.name} (${candidate.id})`).join(", ")
  if (project === undefined)
    return `Pass project: an id or name. Projects on this machine: ${names}`
  return `No project matches "${project}". Projects on this machine: ${names}`
}

const harnessFor = (request: StartAgentRequest, caller: AgentCaller): string => {
  const harnessId = request.harness ?? caller.harnessId
  if (harnessId === undefined) {
    throw new HttpFailure(422, "Pass harness: a harness id from harnesses.list")
  }
  return harnessId
}

const placementFor = async (
  route: RouteContext,
  request: StartAgentRequest,
  plan: AgentPlan,
  created: Array<() => Promise<unknown>>
): Promise<Placement> => {
  if (request.isolation === "shared") return sharedPlacement(plan)
  if (request.isolation === "project") return { workspaceId: randomUUID() }
  const { services, config, fanout } = route
  const allocated = await allocateProjectWorktree(
    { services, config, fanout, serverId: config.id },
    plan.projectId,
    { name: request.title }
  )
  created.push(allocated.rollBack)
  return { workspaceId: randomUUID(), worktreeName: allocated.worktree.name }
}

const sharedPlacement = ({ caller, projectId }: AgentPlan): Placement => {
  if (caller.workspaceId === undefined || caller.projectId !== projectId) {
    throw new HttpFailure(
      422,
      'isolation: "shared" joins your own workspace, so it needs your project on your own machine'
    )
  }
  return {
    workspaceId: caller.workspaceId,
    ...(caller.worktreeName === undefined ? {} : { worktreeName: caller.worktreeName })
  }
}

const optionalFields = (request: StartAgentRequest, plan: AgentPlan) => {
  const configSelections = configSelectionsFor(request.model, plan.harnessId, plan.caller)
  return {
    ...(plan.caller.parentKey === undefined ? {} : { parentSessionId: plan.caller.parentKey }),
    ...(request.labels === undefined ? {} : { labels: request.labels }),
    ...(configSelections === undefined ? {} : { configSelections })
  }
}

const configSelectionsFor = (
  model: string | undefined,
  harnessId: string,
  caller: AgentCaller
): Readonly<Record<string, string>> | undefined => {
  const inherited = caller.harnessId === harnessId ? caller.configSelections : undefined
  if (model !== undefined) return { ...inherited, model }
  if (caller.sessionId === undefined) return inherited
  return undefined
}

const subscribeCaller = async (
  { services }: RouteContext,
  caller: AgentCaller,
  agentId: string
): Promise<boolean> => {
  if (caller.sessionId === undefined) return false
  await run(
    services.db.createSessionSubscription({
      subscriberSessionId: caller.sessionId,
      targetSessionId: agentId,
      events: DEFAULT_SUBSCRIPTION_EVENTS,
      once: false
    })
  )
  return true
}

const sendFirstPrompt = async (route: RouteContext, agentId: string, prompt: string) => {
  const { services, fanout, routeState, config } = route
  await refuseWhileUpdating(services, routeState, agentId)
  const queued = await run(services.db.createPromptQueueItem(agentId, prompt))
  const outcome = await deliverQueuedPrompt(
    services,
    fanout,
    routeState,
    config.id,
    agentId,
    queued.id,
    defaultPromptDelivery
  )
  void drainPromptQueue(services, fanout, routeState, config.id, agentId).catch(() => undefined)
  return outcome.delivered
}

const startedAgent = (session: SessionSummary, placement: Placement) => ({
  agentId: session.id,
  title: session.title,
  projectId: session.projectId,
  ...placement
})

export const rolledBack = async (
  cause: unknown,
  created: ReadonlyArray<() => Promise<unknown>>
): Promise<unknown> => {
  const failures: Array<string> = []
  for (const step of created.toReversed()) {
    await withinCleanupDeadline(step).catch((cleanup: unknown) => {
      failures.push(messageOf(cleanup))
    })
  }
  if (failures.length === 0) return cause
  return new HttpFailure(
    500,
    `${messageOf(cause)} Cleaning up the partly started agent also failed: ${failures.join("; ")}`
  )
}

const withinCleanupDeadline = (step: () => Promise<unknown>): Promise<unknown> => {
  let timer: ReturnType<typeof setTimeout> | undefined
  const deadline = new Promise<never>((_resolve, reject) => {
    timer = setTimeout(() => reject(new Error("cleanup timed out")), AGENT_START_CLEANUP_MS)
    timer.unref()
  })
  return Promise.race([step(), deadline]).finally(() => clearTimeout(timer))
}

const messageOf = (error: unknown): string =>
  error instanceof Error ? error.message : String(error)
