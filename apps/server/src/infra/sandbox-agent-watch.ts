import type { Sandbox } from "@codevisor/api"

import type { SandboxDeps } from "./sandboxes.js"

export type RemoteAgent =
  | { readonly state: "unknown" | "missing" | "archived" }
  | { readonly state: "active"; readonly workspaceId?: string }

type AgentHost = Sandbox & { readonly machineId: string }

const MAX_PAGES = 20

export const remoteAgent = async (
  deps: SandboxDeps,
  machine: AgentHost,
  agentId: string
): Promise<RemoteAgent> => {
  let next: string | undefined
  for (let page = 0; page < MAX_PAGES; page += 1) {
    const listed = await listPage(deps, machine, next)
    if (listed === undefined) return { state: "unknown" }

    const found = listed.items.find((item) => sameId(item["agentId"], agentId))
    if (found !== undefined) return agentIn(found)
    if (listed.next === undefined) return { state: "missing" }
    next = listed.next
  }
  return { state: "unknown" }
}

interface AgentPage {
  readonly items: ReadonlyArray<Record<string, unknown>>
  readonly next?: string
}

const listPage = async (
  deps: SandboxDeps,
  machine: AgentHost,
  next: string | undefined
): Promise<AgentPage | undefined> => {
  const createdByAgentId = machine.agent?.createdByAgentId
  const listed = await deps.remoteTools
    .call(machine.machineId, "codevisor.agents.list", {
      ...(createdByAgentId === undefined ? {} : { createdByAgentId }),
      ...(next === undefined ? {} : { next })
    })
    .catch(() => undefined)
  const items = isRecord(listed) ? listed["items"] : undefined
  if (!isRecord(listed) || !Array.isArray(items)) return undefined

  const following = listed["next"]
  return {
    items: items.filter(isRecord),
    ...(typeof following === "string" ? { next: following } : {})
  }
}

const agentIn = (item: Record<string, unknown>): RemoteAgent => {
  if (item["archived"] === true) return { state: "archived" }
  const workspaceId = item["workspaceId"]
  return typeof workspaceId === "string"
    ? { state: "active", workspaceId: workspaceId.toLowerCase() }
    : { state: "active" }
}

const sameId = (left: unknown, right: string): boolean =>
  typeof left === "string" && left.toLowerCase() === right.toLowerCase()

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null
