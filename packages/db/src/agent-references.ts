import type { CreateSessionRequest, SessionSummary } from "@codevisor/api"

import { canonicalUuid } from "./ids.js"
import type { SessionRow } from "./session-rows.js"

type AgentReferences = Pick<
  SessionSummary,
  "createdByAgentId" | "createdByAgentMachineId" | "forkedFromAgentId" | "forkedFromAgentMachineId"
>

type AgentReferenceValues = readonly [string | null, string | null, string | null, string | null]

export const agentReferencesFromRow = (row: SessionRow): AgentReferences => ({
  ...(row.created_by_agent_id == null ? {} : { createdByAgentId: row.created_by_agent_id }),
  ...(row.created_by_agent_machine_id == null
    ? {}
    : { createdByAgentMachineId: row.created_by_agent_machine_id }),
  ...(row.forked_from_agent_id == null ? {} : { forkedFromAgentId: row.forked_from_agent_id }),
  ...(row.forked_from_agent_machine_id == null
    ? {}
    : { forkedFromAgentMachineId: row.forked_from_agent_machine_id })
})

export const agentReferenceValues = (
  request: CreateSessionRequest,
  localMachineId: string
): AgentReferenceValues => [
  ...reference(request.createdByAgentId, request.createdByAgentMachineId, localMachineId),
  ...reference(request.forkedFromAgentId, request.forkedFromAgentMachineId, localMachineId)
]

const reference = (
  agentId: string | undefined,
  machineId: string | undefined,
  localMachineId: string
): readonly [string | null, string | null] => {
  if (agentId === undefined) return [null, null]
  return [canonicalUuid(agentId), machineId ?? localMachineId]
}
