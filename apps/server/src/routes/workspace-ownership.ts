import { randomUUID } from "node:crypto"

import type { CreateSessionRequest, Workspace } from "@codevisor/api"

import { HttpFailure, run, type CodevisorServerServices } from "../server-context.js"
import { findSession } from "./session-workspace.js"

/// Rejects an owner the database would refuse, as a 409 the caller can act
/// on instead of a 500: the owner must be a live workspace that is neither
/// the child nor one of its descendants.
export const assertWorkspaceOwner = (
  workspaces: ReadonlyArray<Workspace>,
  childId: string,
  ownerId: string
): void => {
  const byId = new Map(workspaces.map((workspace) => [workspace.id.toLowerCase(), workspace]))
  const child = childId.toLowerCase()
  const owner = byId.get(ownerId.toLowerCase())
  if (owner === undefined || owner.isArchived) {
    throw new HttpFailure(409, `Owner workspace is missing or archived: ${ownerId}`)
  }
  const seen = new Set<string>()
  for (let current: Workspace | undefined = owner; current !== undefined;) {
    const id = current.id.toLowerCase()
    if (id === child) {
      throw new HttpFailure(409, `Workspace ${childId} cannot be owned by its own descendant`)
    }
    if (seen.has(id)) break
    seen.add(id)
    current = byId.get(current.parentWorkspaceId?.toLowerCase() ?? "")
  }
}

/// Resolves where an agent-created chat lives (`workspacePlacement`) into a
/// concrete workspace, relative to the workspace of its parent chat:
/// `shared` joins it as another tab, `owned` gets a new workspace that tab
/// groups under it, `independent` gets a new top-level workspace. Without a
/// parent workspace every placement falls back to a new top-level one.
export const resolveSessionPlacement = async (
  services: CodevisorServerServices,
  payload: CreateSessionRequest
): Promise<CreateSessionRequest> => {
  const { workspacePlacement: placement, ...rest } = payload
  if (placement === undefined) return payload
  const parent =
    payload.parentSessionId === undefined
      ? undefined
      : await findSession(services.db, payload.parentSessionId)
  const parentWorkspaceId = parent?.workspaceId
  if (placement === "shared" && parentWorkspaceId !== undefined) {
    return {
      ...rest,
      workspaceId: parentWorkspaceId,
      ...(rest.worktreeName === undefined && parent?.worktreeName !== undefined
        ? { worktreeName: parent.worktreeName }
        : {})
    }
  }
  const owner = placement === "owned" ? parentWorkspaceId : undefined
  return {
    ...rest,
    workspaceId: rest.workspaceId ?? randomUUID(),
    ...(owner === undefined ? {} : { parentWorkspaceId: owner })
  }
}

/// The 409 pre-check for a create that names an owner. A retried create of a
/// workspace that already exists keeps its ownership, so it is not checked.
export const assertCreatableOwner = async (
  services: CodevisorServerServices,
  workspaceId: string,
  ownerId: string | undefined
): Promise<void> => {
  if (ownerId === undefined) return
  const workspaces = await run(services.db.listWorkspaces)
  if (workspaces.some((workspace) => workspace.id.toLowerCase() === workspaceId.toLowerCase())) {
    return
  }
  assertWorkspaceOwner(workspaces, workspaceId, ownerId)
}
