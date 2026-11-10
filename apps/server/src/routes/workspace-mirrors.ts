import { WorkspaceMirrorStartRequest, WorkspaceMirrorWaitRequest } from "@codevisor/api"

import type { MirrorSource, MirrorTarget, WorkspaceMirrors } from "../infra/workspace-mirrors.js"
import { HttpFailure, matchRouteParams, readSchema, run, writeJson } from "../server-context.js"
import type { RouteContext } from "./route-context.js"
import { findWorkspace } from "./workspace-lookups.js"

export const MIRROR_WAIT_DEFAULT_MS = 60_000

export const routeWorkspaceMirrors = async (route: RouteContext): Promise<boolean> => {
  const match = matchMirrorRoute(route.url.pathname)
  if (match === undefined) return false
  const mirrors = requireMirrors(route)
  const workspaceId = await workspaceIdFor(route, match)

  if (match.machine === undefined) return listOrStart(route, mirrors, workspaceId)
  if (match.wait) return waitForMirror(route, mirrors, workspaceId, match.machine)
  return statusOrStop(route, mirrors, workspaceId, match.machine)
}

interface MirrorRouteMatch {
  readonly scope: "session" | "workspace"
  readonly id: string
  readonly machine?: string | undefined
  readonly wait: boolean
}

const MIRROR_PATTERNS: ReadonlyArray<{ pattern: string; scope: MirrorRouteMatch["scope"] }> = [
  { pattern: "/v1/sessions/:id/mirrors", scope: "session" },
  { pattern: "/v1/sessions/:id/mirrors/:machine", scope: "session" },
  { pattern: "/v1/sessions/:id/mirrors/:machine/wait", scope: "session" },
  { pattern: "/v1/workspaces/:id/mirrors", scope: "workspace" },
  { pattern: "/v1/workspaces/:id/mirrors/:machine", scope: "workspace" }
]

const matchMirrorRoute = (pathname: string): MirrorRouteMatch | undefined => {
  for (const { pattern, scope } of MIRROR_PATTERNS) {
    const params = matchRouteParams(pathname, pattern)
    if (params?.id === undefined) continue
    return { scope, id: params.id, machine: params.machine, wait: pattern.endsWith("/wait") }
  }
  return undefined
}

const requireMirrors = (route: RouteContext): WorkspaceMirrors => {
  const mirrors = route.services.workspaceMirrors
  if (mirrors === undefined) throw new HttpFailure(501, "Workspace mirrors aren't available here")
  return mirrors
}

const workspaceIdFor = async (route: RouteContext, match: MirrorRouteMatch): Promise<string> => {
  if (match.scope === "workspace") return match.id
  const session = await run(route.services.db.getSessionSummary(match.id)).catch(() => undefined)
  if (session?.workspaceId === undefined) {
    throw new HttpFailure(409, "This agent isn't in a workspace, so there's nothing to mirror")
  }
  return session.workspaceId
}

const listOrStart = async (
  route: RouteContext,
  mirrors: WorkspaceMirrors,
  workspaceId: string
): Promise<boolean> => {
  if (route.request.method === "GET") {
    writeJson(route.response, 200, { items: await mirrors.list(workspaceId) })
    return true
  }
  if (route.request.method !== "POST") return false

  const body = await readSchema(route.request, WorkspaceMirrorStartRequest)
  const source = await mirrorSource(route, workspaceId)
  writeJson(route.response, 200, await mirrors.start(source, mirrorableTarget(route, body.machine)))
  return true
}

const mirrorableTarget = (route: RouteContext, machine: string): MirrorTarget => {
  const resolved = route.services.machines?.resolve(machine)
  if (resolved !== undefined && resolved !== "self" && resolved.isSandbox === true) {
    throw new HttpFailure(
      400,
      `${resolved.name} is a sandbox, and sandboxes can't hold workspace mirrors. Run commands there with exec, or mirror to one of the user's own machines.`,
      "sandbox_target"
    )
  }
  return resolveTarget(route, machine)
}

const waitForMirror = async (
  route: RouteContext,
  mirrors: WorkspaceMirrors,
  workspaceId: string,
  machine: string
): Promise<boolean> => {
  if (route.request.method !== "POST") return false
  const body = await readSchema(route.request, WorkspaceMirrorWaitRequest)
  const target = resolveTarget(route, machine)
  const waited = await mirrors.wait(
    workspaceId,
    target.id,
    body.timeoutMs ?? MIRROR_WAIT_DEFAULT_MS
  )
  writeJson(route.response, 200, requireSync(waited, target))
  return true
}

const statusOrStop = async (
  route: RouteContext,
  mirrors: WorkspaceMirrors,
  workspaceId: string,
  machine: string
): Promise<boolean> => {
  const target = resolveTarget(route, machine)
  if (route.request.method === "GET") {
    writeJson(
      route.response,
      200,
      requireSync(await mirrors.status(workspaceId, target.id), target)
    )
    return true
  }
  if (route.request.method !== "DELETE") return false
  if (!(await mirrors.stop(workspaceId, target.id))) requireSync(undefined, target)
  writeJson(route.response, 200, { stopped: true })
  return true
}

const mirrorSource = async (route: RouteContext, workspaceId: string): Promise<MirrorSource> => {
  const workspace = await findWorkspace(route.services, workspaceId)
  const root = workspace?.rootDirectory
  if (workspace === undefined || root === undefined) {
    throw new HttpFailure(409, "This workspace has no folder on this machine to mirror")
  }
  return { id: workspace.id, name: workspace.name, root }
}

const resolveTarget = (route: RouteContext, machine: string): MirrorTarget => {
  const resolved = route.services.machines?.resolve(machine)
  if (resolved === "self") {
    throw new HttpFailure(400, "That's this machine; the workspace is already here")
  }
  if (resolved === undefined) {
    throw new HttpFailure(404, `No machine "${machine}" on this account`, "not_found")
  }
  return { id: resolved.id, name: resolved.name }
}

const requireSync = <T>(sync: T | undefined, target: MirrorTarget): T => {
  if (sync !== undefined) return sync
  throw new HttpFailure(404, `This workspace has no mirror on ${target.name}`, "not_found")
}
