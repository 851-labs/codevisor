import { Schema } from "effect"

export const AgentReferenceFields = {
  createdByAgentId: Schema.optional(Schema.String),
  createdByAgentMachineId: Schema.optional(Schema.String),
  forkedFromAgentId: Schema.optional(Schema.String),
  forkedFromAgentMachineId: Schema.optional(Schema.String)
}

export interface AgentRef {
  readonly agentId: string
  readonly machineId: string
}

export const sentByAgentFields = (
  sender: AgentRef | undefined
): { readonly sentByAgentId?: string; readonly sentByAgentMachineId?: string } =>
  sender === undefined
    ? {}
    : { sentByAgentId: sender.agentId, sentByAgentMachineId: sender.machineId }

export const sentByAgentOf = (fields: {
  readonly sentByAgentId?: string | null | undefined
  readonly sentByAgentMachineId?: string | null | undefined
}): AgentRef | undefined => {
  const { sentByAgentId: agentId, sentByAgentMachineId: machineId } = fields
  if (typeof agentId !== "string" || typeof machineId !== "string") return undefined
  return { agentId, machineId }
}
