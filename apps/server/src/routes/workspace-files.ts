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

const workspaceRoots = (root: string): ReadonlyArray<string> => {
  try {
    const real = realpathSync(root)
    return real === root ? [root] : [root, real]
  } catch {
    return [root]
  }
}

const insideRoot = (path: string): string | undefined =>
  path === "" || path === ".." || path.startsWith("../") || isAbsolute(path) ? undefined : path

const workspacePath = (
  roots: ReadonlyArray<string> | undefined,
  path: string
): string | undefined => {
  if (!isAbsolute(path)) return insideRoot(normalize(path))
  for (const root of roots ?? []) {
    const inside = insideRoot(relative(root, path))
    if (inside !== undefined) return inside
  }
  return undefined
}

const editsByPath = (
  roots: ReadonlyArray<string> | undefined,
  edits: ReadonlyArray<WorkspaceFileEdit>
): ReadonlyMap<string, WorkspaceFileEdit> => {
  const byPath = new Map<string, WorkspaceFileEdit>()
  for (const edit of edits) {
    const path = workspacePath(roots, edit.path)
    if (path === undefined) continue
    const seen = byPath.get(path)
    byPath.set(
      path,
      seen === undefined
        ? { ...edit, path }
        : { ...seen, added: seen.added + edit.added, removed: seen.removed + edit.removed }
    )
  }
  return byPath
}

const workingChanges = async (
  services: CodevisorServerServices,
  serverId: string,
  workspace: Workspace
): Promise<{ readonly directory: string; readonly changes: GitWorkingChanges } | undefined> => {
  if (workspace.isArchived) return undefined
  const checkout = await workspaceGitCheckout(services, serverId, workspace)
  if (checkout === undefined) return undefined
  try {
    const env = await (services.resolveGitEnvironment?.(checkout.directory) ??
      Promise.resolve(process.env))
    return {
      directory: checkout.directory,
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

const fileChange = (
  path: string,
  counts: { readonly added: number; readonly removed: number },
  uncommitted: boolean,
  details: {
    readonly status?: WorkspaceFileChange["status"]
    readonly changedAt?: string | undefined
    readonly sessionId?: string | undefined
  }
): WorkspaceFileChange => ({
  path,
  added: counts.added,
  removed: counts.removed,
  uncommitted,
  ...(details.status === undefined ? {} : { status: details.status }),
  ...(details.changedAt === undefined ? {} : { changedAt: details.changedAt }),
  ...(details.sessionId === undefined ? {} : { sessionId: details.sessionId })
})

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
  const roots =
    workspace.rootDirectory === undefined ? undefined : workspaceRoots(workspace.rootDirectory)
  const edits = editsByPath(
    roots,
    await run(services.db.listWorkspaceFileEdits(workspace.id, fileEditLimit))
  )
  const working = await workingChanges(services, serverId, workspace)
  const files: Array<WorkspaceFileChange> = []
  const uncommitted = new Set<string>()
  for (const change of working?.changes.files ?? []) {
    uncommitted.add(change.path)
    const edit = edits.get(change.path)
    files.push(
      fileChange(change.path, change, true, {
        status: change.status,
        changedAt: edit?.changedAt ?? (await modifiedAt(join(working!.directory, change.path))),
        sessionId: edit?.sessionId
      })
    )
  }
  for (const [path, edit] of edits) {
    if (uncommitted.has(path)) continue
    files.push(fileChange(path, edit, false, edit))
  }
  return { files: newestFirst(files), truncated: working?.changes.truncated ?? false }
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
