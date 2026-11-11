import { randomUUID } from "node:crypto"

import { FLEET_AGENTS_ARCHIVED_PATH, type SessionSummary, type Workspace } from "@codevisor/api"
import type { FleetMessage } from "@codevisor/db"

import { fleetLinkFor, type FleetLink } from "./infra/fleet-outbox.js"
import type { CodevisorServerServices } from "./server-context-types.js"
import { run, swallowError } from "./server-http.js"

export type ArchiveChild = (workspace: Workspace) => Promise<void>

export const archiveAgentsCreatedIn = async (
  services: CodevisorServerServices,
  serverId: string,
  workspace: Workspace,
  archive: ArchiveChild
): Promise<void> => {
  const creators = (await run(services.db.listSessions))
    .filter((session) => isIn(session, workspace.id))
    .map((session) => session.id)
  await archiveAgentsCreatedBy(services, serverId, creators, archive)
}

export const archiveAgentsCreatedBy = async (
  services: CodevisorServerServices,
  serverId: string,
  creatorIds: ReadonlyArray<string>,
  archive: ArchiveChild
): Promise<void> => {
  if (creatorIds.length === 0) return

  await archiveLocalChildren(services, { creatorIds, creatorMachineId: serverId }, archive)
  await tellOtherMachines(services, serverId, creatorIds)
}

export const archiveLocalChildren = async (
  services: CodevisorServerServices,
  creators: Creators,
  archive: ArchiveChild
): Promise<number> => {
  const sessions = await run(services.db.listSessions)
  const childWorkspaceIds = new Set(
    sessions.filter((session) => isCreatedBy(session, creators)).flatMap(workspaceIdOf)
  )
  const children = (await run(services.db.listWorkspaces)).filter(
    (workspace) => childWorkspaceIds.has(workspace.id.toLowerCase()) && !workspace.isArchived
  )
  for (const child of children) await archive(child)
  return children.length
}

export interface Creators {
  readonly creatorIds: ReadonlyArray<string>
  readonly creatorMachineId: string
}

const tellOtherMachines = async (
  services: CodevisorServerServices,
  serverId: string,
  creatorIds: ReadonlyArray<string>
): Promise<void> => {
  const fleet = fleetLinkFor(services)
  if (fleet === undefined) return

  const machines = await fleet.machines.list()
  const self = { id: serverId, name: machines.find((machine) => machine.isCurrent)?.name }
  const batch = randomUUID()
  for (const machine of machines.filter((candidate) => !candidate.isCurrent)) {
    await run(services.db.enqueueFleetMessage(archivedMessage(self, machine.id, batch, creatorIds)))
  }
  void flush(fleet)
}

const archivedMessage = (
  self: { readonly id: string; readonly name: string | undefined },
  machineId: string,
  batch: string,
  agentIds: ReadonlyArray<string>
): FleetMessage => ({
  id: `${self.id}:agents_archived:${batch}:${machineId}`,
  machineId,
  path: FLEET_AGENTS_ARCHIVED_PATH,
  args: { agentIds },
  origin: { machineId: self.id, machineName: self.name ?? self.id },
  createdAt: new Date().toISOString()
})

const flush = (fleet: FleetLink): Promise<void> => fleet.outbox.flush().catch(swallowError)

const isIn = (session: SessionSummary, workspaceId: string): boolean =>
  session.workspaceId?.toLowerCase() === workspaceId.toLowerCase()

const isCreatedBy = (session: SessionSummary, creators: Creators): boolean =>
  session.createdByAgentMachineId === creators.creatorMachineId &&
  creators.creatorIds.some((id) => id.toLowerCase() === session.createdByAgentId?.toLowerCase())

const workspaceIdOf = (session: SessionSummary): ReadonlyArray<string> =>
  session.workspaceId === undefined ? [] : [session.workspaceId.toLowerCase()]
