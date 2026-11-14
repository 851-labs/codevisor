import { FLEET_BOTS_PATH } from "@codevisor/api"
import type { FleetBotRecord } from "@codevisor/db"

import { broadcastToOtherMachines } from "../fleet-broadcast.js"
import { HttpFailure, run, type CodevisorServerServices } from "../server-context.js"
import { syncAllBotInstructions } from "./bot-instructions.js"
import type { FleetCall } from "./fleet-calls.js"
import type { RouteContext } from "./route-context.js"

export const botRosterChanged = async (
  services: CodevisorServerServices,
  serverId: string
): Promise<void> => {
  await syncAllBotInstructions(services)
  await broadcastBotRoster(services, serverId)
}

export const broadcastBotRoster = async (
  services: CodevisorServerServices,
  serverId: string
): Promise<void> => {
  const bots = (await run(services.db.listBots))
    .filter((bot) => !bot.isArchived)
    .map((bot) => ({ botId: bot.id, name: bot.name, about: bot.about }))
  await broadcastToOtherMachines(services, serverId, {
    kind: "bots",
    path: FLEET_BOTS_PATH,
    args: { bots }
  })
}

export const receiveBotRoster = async (
  { services }: RouteContext,
  call: FleetCall,
  args: unknown
): Promise<{ readonly bots: number }> => {
  if (!call.verified) throw new HttpFailure(403, "Only machines on this account can list bots")
  const bots = rosterOf(args)
  if (bots === undefined) throw new HttpFailure(400, "Expected { bots: [{ botId, name }] }")

  const { machineId, machineName } = call.origin
  await run(services.db.replaceFleetBots({ machineId, machineName }, bots))
  await syncAllBotInstructions(services)
  return { bots: bots.length }
}

const rosterOf = (args: unknown): ReadonlyArray<FleetBotRecord> | undefined => {
  const value = typeof args === "object" && args !== null ? Reflect.get(args, "bots") : undefined
  if (!Array.isArray(value)) return undefined
  const bots = value.map(botOf)
  return bots.every((bot) => bot !== undefined) ? bots : undefined
}

const botOf = (value: unknown): FleetBotRecord | undefined => {
  if (typeof value !== "object" || value === null) return undefined
  const botId: unknown = Reflect.get(value, "botId")
  const name: unknown = Reflect.get(value, "name")
  const about: unknown = Reflect.get(value, "about")
  if (typeof botId !== "string" || typeof name !== "string") return undefined
  return { botId, name, about: typeof about === "string" ? about : undefined }
}
