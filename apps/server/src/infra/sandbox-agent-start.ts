import type { Sandbox, SandboxAgentStart } from "@codevisor/api"

import { FIRST_AGENT_WAIT, waitForAgent } from "./sandbox-agents.js"
import type { SandboxRemote } from "./sandbox-remote.js"
import type { SandboxSetupProgress } from "./sandbox-setup-log.js"
import { isoNow, type PlacedWorkspace } from "./sandbox-workspace.js"
import type { SandboxDeps } from "./sandboxes.js"

export type StartedSandboxAgent = Pick<Sandbox, "agentId" | "workspaceId" | "workspaceOpenedAt">

export interface AgentHost {
  readonly name: string
  readonly machineId: string
  readonly agent?: SandboxAgentStart | undefined
}

export const startRequestedAgent = async (
  deps: SandboxDeps,
  remote: SandboxRemote,
  host: AgentHost,
  placed: PlacedWorkspace,
  setup: SandboxSetupProgress
): Promise<StartedSandboxAgent> => {
  const { agent } = host
  if (agent === undefined) return {}

  setup.log(`Waiting for ${agent.harness} to be ready on ${host.name}`)
  await waitForAgent(remote, agent.harness, { ...FIRST_AGENT_WAIT, sleep: deps.clock.sleep })
  const started = await deps.remoteTools.call(
    host.machineId,
    "codevisor.agents.start",
    startArguments(agent, placed.remoteProjectId),
    agent.parentSessionId
  )
  setup.log(`Started ${agent.title} on ${host.name}`)
  return { ...startedIds(started), workspaceOpenedAt: isoNow(deps) }
}

const startArguments = (agent: SandboxAgentStart, project: string) => ({
  prompt: agent.prompt,
  title: agent.title,
  isolation: "project",
  harness: agent.harness,
  project,
  ...(agent.model === undefined ? {} : { model: agent.model }),
  ...(agent.labels === undefined ? {} : { labels: agent.labels })
})

const startedIds = (
  started: unknown
): { readonly agentId: string; readonly workspaceId: string } => {
  const agentId = stringField(started, "agentId")
  const workspaceId = stringField(started, "workspaceId")
  if (agentId === undefined || workspaceId === undefined) {
    throw new Error("The sandbox didn't say which agent it started")
  }
  return { agentId, workspaceId: workspaceId.toLowerCase() }
}

const stringField = (value: unknown, key: string): string | undefined => {
  const field = isRecord(value) ? value[key] : undefined
  return typeof field === "string" ? field : undefined
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null
