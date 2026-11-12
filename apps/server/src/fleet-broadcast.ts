import { randomUUID } from "node:crypto"

import type { FleetMessage } from "@codevisor/db"

import { fleetLinkFor, type FleetLink } from "./infra/fleet-outbox.js"
import type { CodevisorServerServices } from "./server-context-types.js"
import { run, swallowError } from "./server-http.js"

export interface FleetBroadcast {
  readonly kind: string
  readonly path: string
  readonly args: Readonly<Record<string, unknown>>
}

export const broadcastToOtherMachines = async (
  services: CodevisorServerServices,
  serverId: string,
  broadcast: FleetBroadcast
): Promise<void> => {
  const fleet = fleetLinkFor(services)
  if (fleet === undefined) return

  const machines = await fleet.machines.list()
  const self = { id: serverId, name: machines.find((machine) => machine.isCurrent)?.name }
  const batch = randomUUID()
  for (const machine of machines.filter((candidate) => !candidate.isCurrent)) {
    await run(services.db.enqueueFleetMessage(fleetMessage(self, machine.id, batch, broadcast)))
  }
  void flush(fleet)
}

interface Sender {
  readonly id: string
  readonly name: string | undefined
}

const fleetMessage = (
  self: Sender,
  machineId: string,
  batch: string,
  broadcast: FleetBroadcast
): FleetMessage => ({
  id: `${self.id}:${broadcast.kind}:${batch}:${machineId}`,
  machineId,
  path: broadcast.path,
  args: broadcast.args,
  origin: { machineId: self.id, machineName: self.name ?? self.id },
  createdAt: new Date().toISOString()
})

const flush = (fleet: FleetLink): Promise<void> => fleet.outbox.flush().catch(swallowError)
