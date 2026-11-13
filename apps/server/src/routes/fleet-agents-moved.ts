import { HttpFailure } from "../server-context.js"
import { moveLocalAgents, type AgentsMove } from "./bot-agents-move.js"
import type { FleetCall } from "./fleet-calls.js"
import type { RouteContext } from "./route-context.js"

export const receiveAgentsMoved = async (
  { services, fanout }: RouteContext,
  call: FleetCall,
  args: unknown
): Promise<{ readonly moved: number }> => {
  if (!call.verified) throw new HttpFailure(403, "Only machines on this account can move agents")
  const move = agentsMoveOf(args)
  if (move === undefined) throw new HttpFailure(400, "Expected { fromAgentId, toAgentId }")

  const creatorMachineId = call.origin.machineId
  const moved = await moveLocalAgents(services, fanout, { ...move, creatorMachineId })
  return { moved: moved.length }
}

const agentsMoveOf = (args: unknown): AgentsMove | undefined => {
  if (typeof args !== "object" || args === null) return undefined
  const fromAgentId: unknown = Reflect.get(args, "fromAgentId")
  const toAgentId: unknown = Reflect.get(args, "toAgentId")
  const toMachineId: unknown = Reflect.get(args, "toMachineId")
  if (typeof fromAgentId !== "string" || typeof toAgentId !== "string") return undefined
  if (typeof toMachineId !== "string") return { fromAgentId, toAgentId }
  return { fromAgentId, toAgentId, toMachineId }
}
