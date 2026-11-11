import type { IncomingMessage } from "node:http"

import { CALLER_AGENT_TICKET_HEADER, FLEET_CALLER_HEADER, type AgentRef } from "@codevisor/api"
import type { GatewayOrigin } from "@codevisor/mcp"

import { withTicket } from "../infra/fleet-tickets.js"
import { HttpFailure, type CodevisorServerServices } from "../server-context.js"

export interface FleetCall {
  readonly origin: GatewayOrigin
  readonly verified: boolean
}

export const fleetCall = (
  services: CodevisorServerServices,
  request: IncomingMessage,
  claimed: GatewayOrigin
): FleetCall => ({
  origin: claimed,
  verified: callerMachineId(services, request) === claimed.machineId
})

export const invokeForFleet = (
  services: CodevisorServerServices,
  call: FleetCall,
  invoke: (callerAgentTicket: string | undefined) => Promise<unknown>
): Promise<unknown> => {
  const caller = verifiedCallerAgent(call)
  const callerAgents = services.fleetTickets?.callerAgents
  if (caller === undefined || callerAgents === undefined) return invoke(undefined)
  return withTicket(callerAgents, caller, invoke)
}

export const remoteCallerAgent = (
  services: CodevisorServerServices,
  request: IncomingMessage
): AgentRef | undefined =>
  services.fleetTickets?.callerAgents.take(headerValue(request, CALLER_AGENT_TICKET_HEADER))

export const assertCreatorVerified = (
  serverId: string,
  creator: Partial<AgentRef>,
  verified: AgentRef | undefined
): void => {
  if (creator.agentId === undefined) return
  if (creator.machineId === undefined || creator.machineId === serverId) return
  if (sameAgent(verified, creator)) return
  throw new HttpFailure(403, "Only the machine an agent runs on can start chats on its behalf")
}

const sameAgent = (verified: AgentRef | undefined, creator: Partial<AgentRef>): boolean =>
  verified !== undefined &&
  verified.agentId === creator.agentId &&
  verified.machineId === creator.machineId

const callerMachineId = (
  services: CodevisorServerServices,
  request: IncomingMessage
): string | undefined => {
  const caller = services.fleetTickets?.callers.take(headerValue(request, FLEET_CALLER_HEADER))
  if (caller === undefined) return undefined
  return services.machines?.machineIdOf(caller)
}

const verifiedCallerAgent = (call: FleetCall): AgentRef | undefined => {
  const { origin } = call
  if (!call.verified || origin.sessionId === undefined) return undefined
  return { agentId: origin.sessionId, machineId: origin.machineId }
}

const headerValue = (request: IncomingMessage, name: string): string | undefined => {
  const value = request.headers[name]
  return typeof value === "string" ? value : undefined
}
