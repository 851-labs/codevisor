import { realpathSync } from "node:fs"
import { stat } from "node:fs/promises"
import type { IncomingMessage, ServerResponse } from "node:http"
import { isAbsolute, join, normalize, relative } from "node:path"

import type { Workspace, WorkspaceFileChange, WorkspaceFileChanges } from "@codevisor/api"
import type { WorkspaceFileEdit } from "@codevisor/db"
import { gitWorkingChanges, type GitWorkingChanges } from "@codevisor/worktrees"

import {
  HttpFailure,
  matchRouteParams,
  run,
  writeJson,
  type CodevisorServerServices
} from "../server-context.js"
import { workspaceGitCheckout } from "../server-workspace-effects.js"
import { routeParam } from "./route-params.js"

const fileEditLimit = 500

const insideRoot = (path: string): string | undefined =>
  path === "" || path === ".." || path.startsWith("../") || isAbsolute(path) ? undefined : path

const workspacePath = (roots: ReadonlyArray<string>, path: string): string | undefined => {
  if (!isAbsolute(path)) return insideRoot(normalize(path))
  for (const root of roots) {
    const inside = insideRoot(relative(root, path))
    if (inside !== undefined) return inside
  }
  return undefined
}

const latestEdits = (
  roots: ReadonlyArray<string>,
  edits: ReadonlyArray<WorkspaceFileEdit>
): ReadonlyMap<string, WorkspaceFileEdit> => {
  const byPath = new Map<string, WorkspaceFileEdit>()
  for (const edit of edits) {
    const path = workspacePath(roots, edit.path)
    if (path !== undefined && !byPath.has(path)) byPath.set(path, edit)
  }
  return byPath
}

const workingChanges = async (
  services: CodevisorServerServices,
  serverId: string,
  workspace: Workspace
): Promise<
  | {
      readonly directory: string
      readonly roots: ReadonlyArray<string>
      readonly changes: GitWorkingChanges
    }
  | undefined
> => {
  if (workspace.isArchived) return undefined
  const checkout = await workspaceGitCheckout(services, serverId, workspace)
  if (checkout === undefined) return undefined
  try {
    const env = await (services.resolveGitEnvironment?.(checkout.directory) ??
      Promise.resolve(process.env))
    const real = realpathSync(checkout.directory)
    return {
      directory: checkout.directory,
      roots: real === checkout.directory ? [real] : [checkout.directory, real],
      changes: await gitWorkingChanges(checkout.directory, env)
    }
  } catch (cause) {
    console.error("Could not read workspace changes:", cause)
    return undefined
  }
}

const modifiedAt = async (path: string): Promise<string | undefined> => {
  try {
    return (await stat(path)).mtime.toISOString()
  } catch {
    return undefined
  }
}

const newestFirst = (
  files: ReadonlyArray<WorkspaceFileChange>
): ReadonlyArray<WorkspaceFileChange> =>
  files
    .map((file) => ({ file, key: file.changedAt ?? "" }))
    .toSorted(
      (left, right) =>
        right.key.localeCompare(left.key) || left.file.path.localeCompare(right.file.path)
    )
    .map(({ file }) => file)

export const workspaceFiles = async (
  services: CodevisorServerServices,
  serverId: string,
  workspace: Workspace
): Promise<WorkspaceFileChanges> => {
  const working = await workingChanges(services, serverId, workspace)
  if (working === undefined) return { files: [], truncated: false }
  const edits = latestEdits(
    working.roots,
    await run(services.db.listWorkspaceFileEdits(workspace.id, fileEditLimit))
  )
  const files: Array<WorkspaceFileChange> = []
  for (const change of working.changes.files) {
    const edit = edits.get(change.path)
    const changedAt = edit?.changedAt ?? (await modifiedAt(join(working.directory, change.path)))
    files.push({
      path: change.path,
      added: change.added,
      removed: change.removed,
      status: change.status,
      uncommitted: true,
      ...(changedAt === undefined ? {} : { changedAt }),
      ...(edit === undefined ? {} : { sessionId: edit.sessionId })
    })
  }
  return { files: newestFirst(files), truncated: working.changes.truncated }
}

export const routeWorkspaceFiles = async (
  services: CodevisorServerServices,
  serverId: string,
  findWorkspace: (workspaceId: string) => Promise<Workspace | undefined>,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (request.method !== "GET") return false
  const route = matchRouteParams(url.pathname, "/v1/workspaces/:workspaceId/files")
  if (route === undefined) return false
  const workspaceId = routeParam(route, "workspaceId")
  const workspace = await findWorkspace(workspaceId)
  if (workspace === undefined) throw new HttpFailure(404, `Workspace not found: ${workspaceId}`)
  writeJson(response, 200, await workspaceFiles(services, serverId, workspace))
  return true
}
