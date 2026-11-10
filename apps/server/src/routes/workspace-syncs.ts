import { WorkspaceSyncStartRequest, WorkspaceSyncWaitRequest } from "@codevisor/api"

import type { SyncSource, SyncTarget, WorkspaceSyncs } from "../infra/workspace-syncs.js"
import { HttpFailure, matchRouteParams, readSchema, run, writeJson } from "../server-context.js"
import type { RouteContext } from "./route-context.js"
import { findWorkspace } from "./workspace-lookups.js"

export const SYNC_WAIT_DEFAULT_MS = 60_000

export const routeWorkspaceSyncs = async (route: RouteContext): Promise<boolean> => {
  const match = matchSyncRoute(route.url.pathname)
  if (match === undefined) return false
  const syncs = requireSyncs(route)
  const workspaceId = await workspaceIdFor(route, match)

  if (match.machine === undefined) return listOrStart(route, syncs, workspaceId)
  if (match.wait) return waitForSync(route, syncs, workspaceId, match.machine)
  return statusOrStop(route, syncs, workspaceId, match.machine)
}

interface SyncRouteMatch {
  readonly scope: "session" | "workspace"
  readonly id: string
  readonly machine?: string | undefined
  readonly wait: boolean
}

const SYNC_PATTERNS: ReadonlyArray<{ pattern: string; scope: SyncRouteMatch["scope"] }> = [
  { pattern: "/v1/sessions/:id/syncs", scope: "session" },
  { pattern: "/v1/sessions/:id/syncs/:machine", scope: "session" },
  { pattern: "/v1/sessions/:id/syncs/:machine/wait", scope: "session" },
  { pattern: "/v1/workspaces/:id/syncs", scope: "workspace" },
  { pattern: "/v1/workspaces/:id/syncs/:machine", scope: "workspace" }
]

const matchSyncRoute = (pathname: string): SyncRouteMatch | undefined => {
  for (const { pattern, scope } of SYNC_PATTERNS) {
    const params = matchRouteParams(pathname, pattern)
    if (params?.id === undefined) continue
    return { scope, id: params.id, machine: params.machine, wait: pattern.endsWith("/wait") }
  }
  return undefined
}

const requireSyncs = (route: RouteContext): WorkspaceSyncs => {
  const syncs = route.services.workspaceSyncs
  if (syncs === undefined) throw new HttpFailure(501, "Workspace sync isn't available here")
  return syncs
}

const workspaceIdFor = async (route: RouteContext, match: SyncRouteMatch): Promise<string> => {
  if (match.scope === "workspace") return match.id
  const session = await run(route.services.db.getSessionSummary(match.id)).catch(() => undefined)
  if (session?.workspaceId === undefined) {
    throw new HttpFailure(409, "This agent isn't in a workspace, so there's nothing to sync")
  }
  return session.workspaceId
}

const listOrStart = async (
  route: RouteContext,
  syncs: WorkspaceSyncs,
  workspaceId: string
): Promise<boolean> => {
  if (route.request.method === "GET") {
    writeJson(route.response, 200, { items: await syncs.list(workspaceId) })
    return true
  }
  if (route.request.method !== "POST") return false

  const body = await readSchema(route.request, WorkspaceSyncStartRequest)
  const source = await syncSource(route, workspaceId)
  writeJson(route.response, 200, await syncs.start(source, syncableTarget(route, body.machine)))
  return true
}

const syncableTarget = (route: RouteContext, machine: string): SyncTarget => {
  const resolved = route.services.machines?.resolve(machine)
  if (resolved !== undefined && resolved !== "self" && resolved.isSandbox === true) {
    throw new HttpFailure(
      400,
      `${resolved.name} is a sandbox, and sandboxes can't be synced to. Run commands there with exec, or sync to one of the user's own machines.`,
      "sandbox_target"
    )
  }
  return resolveTarget(route, machine)
}

const waitForSync = async (
  route: RouteContext,
  syncs: WorkspaceSyncs,
  workspaceId: string,
  machine: string
): Promise<boolean> => {
  if (route.request.method !== "POST") return false
  const body = await readSchema(route.request, WorkspaceSyncWaitRequest)
  const target = resolveTarget(route, machine)
  const waited = await syncs.wait(workspaceId, target.id, body.timeoutMs ?? SYNC_WAIT_DEFAULT_MS)
  writeJson(route.response, 200, requireSync(waited, target))
  return true
}

const statusOrStop = async (
  route: RouteContext,
  syncs: WorkspaceSyncs,
  workspaceId: string,
  machine: string
): Promise<boolean> => {
  const target = resolveTarget(route, machine)
  if (route.request.method === "GET") {
    writeJson(route.response, 200, requireSync(await syncs.status(workspaceId, target.id), target))
    return true
  }
  if (route.request.method !== "DELETE") return false
  if (!(await syncs.stop(workspaceId, target.id))) requireSync(undefined, target)
  writeJson(route.response, 200, { stopped: true })
  return true
}

const syncSource = async (route: RouteContext, workspaceId: string): Promise<SyncSource> => {
  const workspace = await findWorkspace(route.services, workspaceId)
  const root = workspace?.rootDirectory
  if (workspace === undefined || root === undefined) {
    throw new HttpFailure(409, "This workspace has no folder on this machine to sync")
  }
  return { id: workspace.id, name: workspace.name, root }
}

const resolveTarget = (route: RouteContext, machine: string): SyncTarget => {
  const resolved = route.services.machines?.resolve(machine)
  if (resolved === "self") {
    throw new HttpFailure(400, "That's this machine; the workspace is already here")
  }
  if (resolved === undefined) {
    throw new HttpFailure(404, `No machine "${machine}" on this account`, "not_found")
  }
  return { id: resolved.id, name: resolved.name }
}

const requireSync = <T>(sync: T | undefined, target: SyncTarget): T => {
  if (sync !== undefined) return sync
  throw new HttpFailure(404, `This workspace isn't syncing to ${target.name}`, "not_found")
}
