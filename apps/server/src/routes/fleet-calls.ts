import type { IncomingMessage } from "node:http"

import {
  FLEET_CALLER_HEADER,
  parseRemoteSessionKey,
  REMOTE_PARENT_HEADER,
  remoteSessionKey
} from "@codevisor/api"
import type { GatewayOrigin } from "@codevisor/mcp"

import { withTicket, type VerifiedRemoteParent } from "../infra/fleet-tickets.js"
import { HttpFailure, type CodevisorServerServices } from "../server-context.js"

export interface FleetCall {
  readonly origin: GatewayOrigin
  readonly verified: boolean
}

export const fleetCall = (
  services: CodevisorServerServices,
  request: IncomingMessage,
  claimed: GatewayOrigin
): FleetCall => {
  const verified = callerMachineId(services, request) === claimed.machineId
  if (verified) return { origin: claimed, verified }

  const { botId: _botId, botMachineId: _botMachineId, ...origin } = claimed
  return { origin, verified }
}

export const invokeForFleet = (
  services: CodevisorServerServices,
  call: FleetCall,
  invoke: (remoteParent: string | undefined) => Promise<unknown>
): Promise<unknown> => {
  const parent = verifiedParentOf(call)
  const remoteParents = services.fleetTickets?.remoteParents
  if (parent === undefined || remoteParents === undefined) return invoke(undefined)
  return withTicket(remoteParents, parent, invoke)
}

export const verifiedRemoteParent = (
  services: CodevisorServerServices,
  request: IncomingMessage,
  parentSessionId: string | undefined
): VerifiedRemoteParent | undefined => {
  const parent = services.fleetTickets?.remoteParents.take(
    headerValue(request, REMOTE_PARENT_HEADER)
  )
  if (parent === undefined || parent.parentSessionId !== parentSessionId) return undefined
  return parent
}

export const assertRemoteParentVerified = (
  parentSessionId: string | undefined,
  verified: VerifiedRemoteParent | undefined
): void => {
  if (parentSessionId === undefined || parseRemoteSessionKey(parentSessionId) === undefined) return
  if (verified?.parentSessionId === parentSessionId) return
  throw new HttpFailure(
    403,
    "Only the machine that owns a remote parent session can start chats under it"
  )
}

const callerMachineId = (
  services: CodevisorServerServices,
  request: IncomingMessage
): string | undefined => {
  const caller = services.fleetTickets?.callers.take(headerValue(request, FLEET_CALLER_HEADER))
  if (caller === undefined) return undefined
  return services.machines?.machineIdOf(caller)
}

const verifiedParentOf = (call: FleetCall): VerifiedRemoteParent | undefined => {
  const { origin } = call
  if (!call.verified || origin.sessionId === undefined) return undefined
  return {
    parentSessionId: remoteSessionKey(origin.machineId, origin.sessionId),
    ...botOf(origin)
  }
}

const botOf = (origin: GatewayOrigin): Pick<VerifiedRemoteParent, "bot"> => {
  if (origin.botId === undefined) return {}
  return { bot: { botId: origin.botId, botMachineId: origin.botMachineId ?? origin.machineId } }
}

const headerValue = (request: IncomingMessage, name: string): string | undefined => {
  const value = request.headers[name]
  return typeof value === "string" ? value : undefined
}
