import type { Workspace } from "@codevisor/api"

import { HttpFailure, run } from "../server-context.js"
import type { CodevisorServerServices } from "../server-context.js"

interface IdentifiedBody {
  readonly id?: string | undefined
}

export const findWorkspace = async (
  services: CodevisorServerServices,
  workspaceId: string
): Promise<Workspace | undefined> =>
  workspaceWithId(await run(services.db.listWorkspaces), workspaceId)

export const workspaceWithId = (
  workspaces: ReadonlyArray<Workspace>,
  workspaceId: string
): Workspace | undefined => workspaces.find((candidate) => sameId(candidate.id, workspaceId))

export const requireWorkspace = (
  workspace: Workspace | undefined,
  workspaceId: string
): Workspace => {
  if (workspace === undefined) throw new HttpFailure(404, `Workspace not found: ${workspaceId}`)
  return workspace
}

export const refuseMismatchedBodyId = (
  resource: string,
  body: IdentifiedBody,
  pathId: string
): void => {
  if (bodyIdDiffers(body, pathId)) {
    throw new HttpFailure(
      400,
      `${resource} id in the body (${body.id}) does not match the path (${pathId})`
    )
  }
}

export const sameId = (left: string, right: string): boolean =>
  left.toLowerCase() === right.toLowerCase()

const bodyIdDiffers = (body: IdentifiedBody, pathId: string): boolean =>
  body.id !== undefined && !sameId(body.id, pathId)
