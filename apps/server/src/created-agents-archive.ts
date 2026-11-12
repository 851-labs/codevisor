import { FLEET_AGENTS_ARCHIVED_PATH, type SessionSummary, type Workspace } from "@codevisor/api"

import { broadcastToOtherMachines } from "./fleet-broadcast.js"
import type { CodevisorServerServices } from "./server-context-types.js"
import { run } from "./server-http.js"

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
    sessions.filter((session) => isOwnedBy(session, creators)).flatMap(workspaceIdOf)
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

const tellOtherMachines = (
  services: CodevisorServerServices,
  serverId: string,
  creatorIds: ReadonlyArray<string>
): Promise<void> =>
  broadcastToOtherMachines(services, serverId, {
    kind: "agents_archived",
    path: FLEET_AGENTS_ARCHIVED_PATH,
    args: { agentIds: creatorIds }
  })

const isIn = (session: SessionSummary, workspaceId: string): boolean =>
  session.workspaceId?.toLowerCase() === workspaceId.toLowerCase()

const isOwnedBy = (session: SessionSummary, creators: Creators): boolean =>
  session.isDetached !== true &&
  session.createdByAgentMachineId === creators.creatorMachineId &&
  creators.creatorIds.some((id) => id.toLowerCase() === session.createdByAgentId?.toLowerCase())

const workspaceIdOf = (session: SessionSummary): ReadonlyArray<string> =>
  session.workspaceId === undefined ? [] : [session.workspaceId.toLowerCase()]
