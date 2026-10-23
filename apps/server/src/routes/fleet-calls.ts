import type { IncomingMessage } from "node:http"

import { BOT_LINK_HEADER, FLEET_CALLER_HEADER, remoteSessionKey } from "@codevisor/api"
import type { GatewayOrigin } from "@codevisor/mcp"

import { withTicket, type RemoteBotLink } from "../infra/fleet-tickets.js"
import type { CodevisorServerServices } from "../server-context.js"

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
  origin: GatewayOrigin,
  invoke: (botLink: string | undefined) => Promise<unknown>
): Promise<unknown> => {
  const link = remoteBotLink(origin)
  const botLinks = services.fleetTickets?.botLinks
  if (link === undefined || botLinks === undefined) return invoke(undefined)
  return withTicket(botLinks, link, invoke)
}

export const verifiedBotLink = (
  services: CodevisorServerServices,
  request: IncomingMessage,
  parentSessionId: string | undefined
): RemoteBotLink | undefined => {
  const link = services.fleetTickets?.botLinks.take(headerValue(request, BOT_LINK_HEADER))
  if (link === undefined || link.parentSessionId !== parentSessionId) return undefined
  return link
}

const callerMachineId = (
  services: CodevisorServerServices,
  request: IncomingMessage
): string | undefined => {
  const caller = services.fleetTickets?.callers.take(headerValue(request, FLEET_CALLER_HEADER))
  if (caller === undefined) return undefined
  return services.machines?.machineIdOf(caller)
}

const remoteBotLink = (origin: GatewayOrigin): RemoteBotLink | undefined => {
  if (origin.botId === undefined || origin.sessionId === undefined) return undefined
  return {
    parentSessionId: remoteSessionKey(origin.machineId, origin.sessionId),
    bot: { botId: origin.botId, botMachineId: origin.botMachineId ?? origin.machineId }
  }
}

const headerValue = (request: IncomingMessage, name: string): string | undefined => {
  const value = request.headers[name]
  return typeof value === "string" ? value : undefined
}
