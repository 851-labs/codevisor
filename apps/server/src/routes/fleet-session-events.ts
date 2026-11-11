import {
  HttpFailure,
  run,
  sessionIsArchived,
  type CodevisorServerServices,
  type RouteState
} from "../server-context.js"
import { stringField } from "../unknown-values.js"
import type { FleetCall } from "./fleet-calls.js"

export interface FleetSessionEvent {
  readonly sessionId: string
  readonly deliveryId: string
  readonly text: string
}

export const receiveSessionEvent = async (
  services: CodevisorServerServices,
  routeState: RouteState,
  call: FleetCall,
  args: unknown
): Promise<boolean> => {
  if (!call.verified) throw new HttpFailure(403, "Only machines on this account can send events")
  const event = parseFleetSessionEvent(args)
  if (event === undefined) throw new HttpFailure(400, "Expected { sessionId, deliveryId, text }")
  const target = await run(services.db.getSessionSummary(event.sessionId)).catch(() => undefined)
  if (target === undefined) throw new HttpFailure(404, "No such session on this machine")
  if (await sessionIsArchived(services, target)) throw new HttpFailure(409, "That chat is archived")

  const accepted = await run(
    services.db.acceptFleetPrompt({
      deliveryId: event.deliveryId,
      receivedAt: new Date().toISOString(),
      sessionId: target.id,
      text: event.text
    })
  )
  if (accepted) void routeState.drainSessionQueue?.(target.id)
  return accepted
}

const parseFleetSessionEvent = (value: unknown): FleetSessionEvent | undefined => {
  const sessionId = stringField(value, "sessionId")
  const deliveryId = stringField(value, "deliveryId")
  const text = stringField(value, "text")
  if (sessionId === undefined || deliveryId === undefined || text === undefined) return undefined
  return { sessionId, deliveryId, text }
}
