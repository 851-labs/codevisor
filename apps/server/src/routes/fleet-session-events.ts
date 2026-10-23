import {
  FLEET_SESSION_EVENT_PATH,
  remoteSessionKey,
  type RemoteSessionRef,
  type SessionSummary
} from "@codevisor/api"

import type { MachineLink } from "../infra/machine-link.js"
import {
  HttpFailure,
  run,
  type CodevisorServerServices,
  type RouteState
} from "../server-context.js"
import { isRecord } from "../unknown-values.js"
import type { FleetCall } from "./fleet-calls.js"
import { fromMachine, type SessionEventMessage } from "./session-event-messages.js"

export interface FleetSessionEvent {
  readonly sessionId: string
  readonly key: string
  readonly text: string
}

export const isLinkedRemoteChild = async (
  services: CodevisorServerServices,
  child: SessionSummary,
  parent: RemoteSessionRef
): Promise<boolean> => {
  const link = await run(services.db.findBotLinkForSession(child.id))
  return link?.botMachineId === parent.machineId
}

export const forwardSessionEvent = async (
  machines: MachineLink | undefined,
  serverId: string,
  source: Pick<SessionSummary, "id" | "title">,
  subscriber: RemoteSessionRef,
  message: SessionEventMessage
): Promise<void> => {
  if (machines === undefined) return

  const self = { id: serverId, name: await currentMachineName(machines, serverId) }
  const attributed = fromMachine(message, self)
  const event: FleetSessionEvent = {
    sessionId: subscriber.sessionId,
    key: attributed.key,
    text: attributed.text
  }
  await machines.invoke(subscriber.machineId, FLEET_SESSION_EVENT_PATH, event, {
    machineId: self.id,
    machineName: self.name,
    sessionId: source.id,
    sessionTitle: source.title
  })
}

export const receiveSessionEvent = async (
  services: CodevisorServerServices,
  routeState: RouteState,
  call: FleetCall,
  args: unknown
): Promise<void> => {
  if (!call.verified) throw new HttpFailure(403, "Only machines on this account can send events")
  const event = parseFleetSessionEvent(args)
  if (event === undefined) throw new HttpFailure(400, "Expected { sessionId, key, text }")
  const target = await run(services.db.getSessionSummary(event.sessionId)).catch(() => undefined)
  if (target === undefined) throw new HttpFailure(404, "No such session on this machine")

  await routeState.deliverSessionEvent?.(event.sessionId, {
    message: { key: event.key, text: event.text },
    sourceSessionId: remoteSessionKey(call.origin.machineId, call.origin.sessionId)
  })
}

const currentMachineName = async (machines: MachineLink, serverId: string): Promise<string> =>
  (await machines.list()).find((machine) => machine.isCurrent)?.name ?? serverId

const parseFleetSessionEvent = (value: unknown): FleetSessionEvent | undefined => {
  if (!isRecord(value)) return undefined
  const { sessionId, key, text } = value
  if (typeof sessionId !== "string" || typeof key !== "string" || typeof text !== "string") {
    return undefined
  }
  return { sessionId, key, text }
}
