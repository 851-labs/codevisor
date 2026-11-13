import { archiveAgentsOfRemote, closeTabsOfRemoteChats } from "../archive-jobs.js"
import { HttpFailure } from "../server-context.js"
import type { FleetCall } from "./fleet-calls.js"
import type { RouteContext } from "./route-context.js"

export const receiveAgentsArchived = async (
  { services, fanout, config, routeState }: RouteContext,
  call: FleetCall,
  args: unknown
): Promise<{ readonly archived: number }> => {
  if (!call.verified) throw new HttpFailure(403, "Only machines on this account can archive agents")
  const creatorIds = agentIdsOf(args)
  if (creatorIds === undefined) throw new HttpFailure(400, "Expected { agentIds: string[] }")

  const creators = { creatorIds, creatorMachineId: call.origin.machineId }
  const context = { services, fanout, config, turns: routeState }
  await closeTabsOfRemoteChats(context, creators)
  return { archived: await archiveAgentsOfRemote(context, creators) }
}

const agentIdsOf = (args: unknown): ReadonlyArray<string> | undefined => {
  const value =
    typeof args === "object" && args !== null ? Reflect.get(args, "agentIds") : undefined
  if (!Array.isArray(value) || !value.every((id) => typeof id === "string")) return undefined
  return value
}
