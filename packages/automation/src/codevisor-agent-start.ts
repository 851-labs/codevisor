import { randomUUID } from "node:crypto"

import { Labels, Project, PromptAcceptedResponse, SessionSummary, Worktree } from "@codevisor/api"
import { Schema } from "effect"

import { callerSession, type AgentCaller } from "./codevisor-agent-caller.js"
import type { AgentToolContext } from "./codevisor-agent-tool.js"

export const AgentIsolation = Schema.Literals(["worktree", "shared", "project"])

export const CallerDefaults = Schema.Struct({
  harness: Schema.String,
  configSelections: Schema.optional(Schema.Record(Schema.String, Schema.String))
})
export type CallerDefaults = typeof CallerDefaults.Type

export const StartAgentArgs = Schema.Struct({
  prompt: Schema.String,
  title: Schema.String,
  isolation: AgentIsolation,
  harness: Schema.optional(Schema.String),
  model: Schema.optional(Schema.String),
  project: Schema.optional(Schema.String),
  labels: Schema.optional(Labels),
  callerDefaults: Schema.optional(CallerDefaults)
})
type StartAgentArgs = typeof StartAgentArgs.Type

export interface StartedAgent {
  readonly agentId: string
  readonly title: string
  readonly projectId: string
  readonly workspaceId?: string
  readonly worktreeName?: string
  readonly delivered?: string
  readonly subscribed: boolean
}

export const startAgent = async (tool: AgentToolContext, raw: unknown): Promise<StartedAgent> => {
  const args = Schema.decodeUnknownSync(StartAgentArgs)(raw)
  const caller = await callerSession(tool, args.callerDefaults)
  const projectId = await resolveProjectId(tool, args.project, caller)
  const harnessId = harnessFor(args, caller)

  const rollback = makeRollback()
  try {
    return await startPlanned(tool, args, { projectId, harnessId, caller }, rollback)
  } catch (cause) {
    throw await rollback.undo(cause)
  }
}

const startPlanned = async (
  tool: AgentToolContext,
  args: StartAgentArgs,
  plan: Omit<AgentPlan, "placement">,
  rollback: Rollback
): Promise<StartedAgent> => {
  const placement = await placementFor(tool, args, plan.projectId, plan.caller, rollback)
  const agent = await createAgent(tool, args, { ...plan, placement })
  rollback.push(() => tool.api("DELETE", `/v1/sessions/${encodeURIComponent(agent.id)}`))
  const subscribed = await subscribeCaller(tool, agent.id, plan.caller)
  const delivery = await sendFirstPrompt(tool, agent.id, args.prompt)

  return {
    agentId: agent.id,
    title: agent.title,
    projectId: agent.projectId,
    ...(agent.workspaceId === undefined ? {} : { workspaceId: agent.workspaceId }),
    ...(agent.worktreeName === undefined ? {} : { worktreeName: agent.worktreeName }),
    ...(delivery.delivered === undefined ? {} : { delivered: delivery.delivered }),
    subscribed
  }
}

export const resolveProjectId = async (
  tool: AgentToolContext,
  project: string | undefined,
  caller: AgentCaller
): Promise<string> => {
  if (project === undefined && caller.projectId !== undefined) return caller.projectId
  const projects = Schema.decodeUnknownSync(Schema.Array(Project))(
    await tool.api("GET", "/v1/projects")
  )
  const wanted = project?.toLowerCase()
  const found = projects.find((candidate) => matchesProject(candidate, wanted))
  if (found !== undefined) return found.id
  throw new Error(projectHint(project, projects))
}

interface Placement {
  readonly workspaceId: string
  readonly worktreeName?: string
}

interface AgentPlan {
  readonly projectId: string
  readonly harnessId: string
  readonly placement: Placement
  readonly caller: AgentCaller
}

const matchesProject = (project: Project, wanted: string | undefined): boolean =>
  wanted !== undefined &&
  (project.id.toLowerCase() === wanted || project.name.toLowerCase() === wanted)

const projectHint = (project: string | undefined, projects: ReadonlyArray<Project>): string => {
  const names =
    projects.map((candidate) => `${candidate.name} (${candidate.id})`).join(", ") || "none"
  if (project === undefined)
    return `Pass project: an id or name. Projects on this machine: ${names}`
  return `No project matches "${project}". Projects on this machine: ${names}`
}

const harnessFor = (args: StartAgentArgs, caller: AgentCaller): string => {
  const harnessId = args.harness ?? caller.harnessId
  if (harnessId === undefined) throw new Error("Pass harness: a harness id from harnesses.list")
  return harnessId
}

const placementFor = async (
  tool: AgentToolContext,
  args: StartAgentArgs,
  projectId: string,
  caller: AgentCaller,
  rollback: Rollback
): Promise<Placement> => {
  if (args.isolation === "shared") return sharedPlacement(projectId, caller)
  if (args.isolation === "project") return { workspaceId: randomUUID() }
  const worktrees = `/v1/projects/${encodeURIComponent(projectId)}/worktrees`
  const worktree = Schema.decodeUnknownSync(Worktree)(
    await tool.api("POST", worktrees, { body: { name: args.title } })
  )
  rollback.push(() => tool.api("DELETE", `${worktrees}/${encodeURIComponent(worktree.id)}`))
  return { workspaceId: randomUUID(), worktreeName: worktree.name }
}

interface Rollback {
  readonly push: (step: () => Promise<unknown>) => void
  readonly undo: (cause: unknown) => Promise<unknown>
}

const makeRollback = (): Rollback => {
  const steps: Array<() => Promise<unknown>> = []
  return {
    push: (step) => {
      steps.push(step)
    },
    undo: async (cause) => {
      try {
        for (const step of steps.toReversed()) await step()
        return cause
      } catch (cleanup) {
        return new Error(
          `${messageOf(cause)} Cleaning up the partly started agent also failed: ${messageOf(cleanup)}`
        )
      }
    }
  }
}

const messageOf = (error: unknown): string =>
  error instanceof Error ? error.message : String(error)

const sharedPlacement = (projectId: string, caller: AgentCaller): Placement => {
  if (caller.workspaceId === undefined || caller.projectId !== projectId) {
    throw new Error(
      'isolation: "shared" joins your own workspace, so it needs your project on your own machine'
    )
  }
  return {
    workspaceId: caller.workspaceId,
    ...(caller.worktreeName === undefined ? {} : { worktreeName: caller.worktreeName })
  }
}

const createAgent = async (
  tool: AgentToolContext,
  args: StartAgentArgs,
  plan: AgentPlan
): Promise<SessionSummary> => {
  const configSelections = configSelectionsFor(args.model, plan.harnessId, plan.caller)
  const created = await tool.api("POST", "/v1/sessions", {
    body: {
      projectId: plan.projectId,
      harnessId: plan.harnessId,
      title: args.title,
      ...plan.placement,
      ...(plan.caller.sessionId === undefined ? {} : { parentSessionId: plan.caller.sessionId }),
      ...(args.labels === undefined ? {} : { labels: args.labels }),
      ...(configSelections === undefined ? {} : { configSelections })
    }
  })
  return Schema.decodeUnknownSync(SessionSummary)(created)
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

const sendFirstPrompt = async (
  tool: AgentToolContext,
  agentId: string,
  prompt: string
): Promise<PromptAcceptedResponse> =>
  Schema.decodeUnknownSync(PromptAcceptedResponse)(
    await tool.api("POST", `/v1/sessions/${encodeURIComponent(agentId)}/prompt`, {
      body: { text: prompt, fromSessionId: tool.context.sessionId }
    })
  )

const subscribeCaller = async (
  tool: AgentToolContext,
  agentId: string,
  caller: AgentCaller
): Promise<boolean> => {
  if (caller.sessionId === undefined) return false
  await tool.api("POST", `/v1/sessions/${encodeURIComponent(caller.sessionId)}/subscriptions`, {
    body: { targetSessionId: agentId }
  })
  return true
}
