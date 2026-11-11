import {
  FLEET_SESSION_EVENT_PATH,
  type SessionEventType,
  type SessionSummary
} from "@codevisor/api"
import type { FleetMessage } from "@codevisor/db"

import type { FleetLink } from "../infra/fleet-outbox.js"
import { run, swallowError, type CodevisorServerServices } from "../server-context.js"
import { fromMachine, type SessionEventMessage } from "./session-event-messages.js"

export interface RemoteCreatorEvents {
  readonly notify: (
    target: SessionSummary,
    type: SessionEventType,
    message: SessionEventMessage,
    occurrence: string
  ) => Promise<void>
  readonly flush: () => Promise<void>
}

export const makeRemoteCreatorEvents = (
  services: CodevisorServerServices,
  serverId: string,
  fleet: FleetLink | undefined
): RemoteCreatorEvents => {
  if (fleet === undefined) return { notify: async () => undefined, flush: async () => undefined }

  return {
    notify: async (target, type, message, occurrence) => {
      const creator = remoteCreatorOf(target, serverId)
      if (creator === undefined) return

      const self = { id: serverId, name: await machineName(fleet, serverId) }
      const event = { target, type, occurrence, text: fromMachine(message, self).text }
      await run(services.db.enqueueFleetMessage(fleetMessage(self, creator, event)))
      void fleet.outbox.flush().catch(swallowError)
    },
    flush: () => fleet.outbox.flush()
  }
}

interface Creator {
  readonly agentId: string
  readonly machineId: string
}

interface CreatorEvent {
  readonly target: SessionSummary
  readonly type: SessionEventType
  readonly occurrence: string
  readonly text: string
}

const remoteCreatorOf = (target: SessionSummary, serverId: string): Creator | undefined => {
  const agentId = target.createdByAgentId
  const machineId = target.createdByAgentMachineId
  if (agentId === undefined || machineId === undefined || machineId === serverId) return undefined
  return { agentId, machineId }
}

const fleetMessage = (
  self: { readonly id: string; readonly name: string },
  creator: Creator,
  event: CreatorEvent
): FleetMessage => {
  const id = `${self.id}:${event.type}:${event.target.id}:${event.occurrence}`
  return {
    id,
    machineId: creator.machineId,
    path: FLEET_SESSION_EVENT_PATH,
    args: { sessionId: creator.agentId, deliveryId: id, text: event.text },
    origin: {
      machineId: self.id,
      machineName: self.name,
      sessionId: event.target.id,
      sessionTitle: event.target.title
    },
    createdAt: new Date().toISOString()
  }
}

const machineName = async (fleet: FleetLink, serverId: string): Promise<string> =>
  (await fleet.machines.list()).find((machine) => machine.isCurrent)?.name ?? serverId
