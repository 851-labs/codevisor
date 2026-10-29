import type { ServerResponse } from "node:http"

import type {
  EventEnvelope,
  GitHead,
  SessionSummary,
  Workspace,
  WorkspaceGit
} from "@codevisor/api"
import {
  UpdateWorkspaceRequest as UpdateWorkspaceRequestSchema,
  UpsertWorkspaceRequest as UpsertWorkspaceRequestSchema
} from "@codevisor/api"
import { gitHead } from "@codevisor/worktrees"

import { gitHostsOf } from "../infra/git-hosts.js"
import {
  appendAndPublish,
  applyWorkspaceArchiveEffects,
  captureWorkspaceRuntime,
  enqueueWorkspaceArchive,
  matchRoute,
  matchRouteParams,
  readSchema,
  run,
  workspaceGitCheckout,
  writeJson
} from "../server-context.js"
import type { CodevisorServerServices, WorkspaceGitCheckout } from "../server-context.js"
import { assertNotOwnedByBot } from "./bot-guards.js"
import { cachedPullRequest } from "./git-review.js"
import { matchesLabelFilters } from "./label-filters.js"
import { rejectSyncThrows } from "./route-context.js"
import type { RouteContext } from "./route-context.js"
import { routeParam } from "./route-params.js"
import { restoreSandboxWhenUnarchived } from "./sandbox-restore.js"
import { routeWorkspaceArchive } from "./workspace-archive.js"
import { routeWorkspaceCreate } from "./workspace-create.js"
import { routeWorkspaceFiles } from "./workspace-files.js"
import {
  findWorkspace,
  refuseMismatchedBodyId,
  requireWorkspace,
  sameId
} from "./workspace-lookups.js"
import { routeWorkspaceMedia } from "./workspace-media.js"
import { routeWorkspacePanes } from "./workspace-panes.js"

export const routeWorkspaces = (route: RouteContext): Promise<boolean> =>
  rejectSyncThrows(() => dispatchWorkspaceRoute(route))

const dispatchWorkspaceRoute = (route: RouteContext): Promise<boolean> => {
  const { request, url } = route
  if (request.method === "GET" && url.pathname === "/v1/workspaces") return listWorkspaces(route)
  return routeAfterDelegates(route)
}

const routeAfterDelegates = async (route: RouteContext): Promise<boolean> => {
  const { services, fanout, request, response, url, config } = route
  if (await routeWorkspaceCreate(services, fanout, config, request, response, url)) {
    return true
  }

  if (
    await routeWorkspaceMedia(
      services,
      (workspaceId) => findWorkspace(services, workspaceId),
      request,
      response,
      url
    )
  ) {
    return true
  }

  if (
    await routeWorkspaceFiles(
      services,
      config.id,
      (workspaceId) => findWorkspace(services, workspaceId),
      request,
      response,
      url
    )
  ) {
    return true
  }

  return (
    routeWorkspaceReads(route) ??
    routeWorkspaceArchive(route) ??
    routeWorkspacePanes(route) ??
    routeWorkspace(route) ??
    false
  )
}

const routeWorkspaceReads = (route: RouteContext): Promise<boolean> | undefined => {
  const { request, url } = route
  const gitRoute = matchRouteParams(url.pathname, "/v1/workspaces/:workspaceId/git")
  if (gitRoute !== undefined && request.method === "GET") return readWorkspaceGit(route, gitRoute)

  if (request.method === "GET" && url.pathname === "/v1/workspace-snapshot")
    return readWorkspaceSnapshot(route)
  return undefined
}

const routeWorkspace = (route: RouteContext): Promise<boolean> | undefined => {
  const { request, url } = route
  const workspaceId = matchRoute(url.pathname, "/v1/workspaces/:id")
  if (workspaceId !== undefined && request.method === "PUT")
    return upsertWorkspace(route, workspaceId)
  if (workspaceId !== undefined && request.method === "PATCH")
    return updateWorkspace(route, workspaceId)
  if (workspaceId !== undefined && request.method === "DELETE")
    return deleteWorkspace(route, workspaceId)
  return undefined
}

const listWorkspaces = async ({ services, response, url }: RouteContext): Promise<boolean> => {
  const workspaces = await run(services.db.listWorkspaces)
  writeJson(
    response,
    200,
    workspaces.filter((workspace) => matchesLabelFilters(workspace.labels, url))
  )
  return true
}

const readWorkspaceGit = async (
  { services, response, url, config }: RouteContext,
  params: Readonly<Record<string, string>>
): Promise<boolean> => {
  const workspaceId = routeParam(params, "workspaceId")
  const workspace = requireWorkspace(await findWorkspace(services, workspaceId), workspaceId)
  const includePullRequest = url.searchParams.get("pullRequest") === "true"
  writeJson(response, 200, await workspaceGit(services, config.id, workspace, includePullRequest))
  return true
}

const readWorkspaceSnapshot = async ({ services, response }: RouteContext): Promise<boolean> => {
  writeJson(response, 200, await run(services.db.getWorkspaceSnapshot))
  return true
}

const upsertWorkspace = async (route: RouteContext, workspaceId: string): Promise<boolean> => {
  const { services, request, response } = route
  const payload = await readSchema(request, UpsertWorkspaceRequestSchema)
  refuseMismatchedBodyId("Workspace", payload, workspaceId)
  if (payload.isArchived === true) await refuseBotArchive(services, workspaceId)

  const wasArchived = isArchivedIn(await run(services.db.listWorkspaces), workspaceId)
  const workspace = await run(services.db.upsertWorkspace({ ...payload, id: workspaceId }))
  const settled = await applyArchiveEffects(route, workspace, wasArchived)
  restoreSandboxWhenUnarchived(route, settled, wasArchived)
  writeJson(response, 200, settled)
  return true
}

const updateWorkspace = async (route: RouteContext, workspaceId: string): Promise<boolean> => {
  const { services, request, response } = route
  const payload = await readSchema(request, UpdateWorkspaceRequestSchema)
  const existing = requireWorkspace(await findWorkspace(services, workspaceId), workspaceId)
  if (payload.isArchived === true) await refuseBotArchive(services, workspaceId)

  const wasArchived = existing.isArchived
  const workspace = await run(services.db.updateWorkspace(workspaceId, payload))
  const settled = await applyArchiveEffects(route, workspace, wasArchived)
  restoreSandboxWhenUnarchived(route, settled, wasArchived)
  writeJson(response, 200, settled)
  return true
}

const deleteWorkspace = async (route: RouteContext, workspaceId: string): Promise<boolean> => {
  const { services, fanout, routeState, response, config } = route
  await refuseBotDelete(services, workspaceId)
  if ((await findWorkspace(services, workspaceId)) === undefined) return noContent(response)

  const workspace = await archiveWorkspace(services, workspaceId)
  await publishWorkspaceUpdated(route, workspace)
  const runtime = await captureWorkspaceRuntime(services, routeState, workspace)
  for (const session of await allSessions(services)) {
    if (isInWorkspace(session, workspaceId)) await detachSession(services, session)
  }
  await run(services.db.deleteWorkspace(workspaceId))
  await publishWorkspaceDeleted(route, workspaceId)
  void enqueueWorkspaceArchive(services, fanout, config, workspace, runtime)
  return noContent(response)
}

const workspaceGit = async (
  services: CodevisorServerServices,
  serverId: string,
  workspace: Workspace,
  includePullRequest: boolean
): Promise<WorkspaceGit> => {
  const checkout = await workspaceGitCheckout(services, serverId, workspace)
  if (checkout === undefined) {
    return includePullRequest ? { branch: null, pullRequest: null } : { branch: null }
  }

  const env = await gitEnvironment(services, checkout)
  const head = await checkoutHead(checkout, env)
  const branch = head.branch
  if (!includePullRequest) return head
  if (branch === null) return { ...head, pullRequest: null }

  const owned = checkout.ownedBranch
  return {
    ...head,
    pullRequest: await cachedPullRequest(gitHostsOf(services), checkout.directory, env, {
      branch,
      owned
    })
  }
}

const gitEnvironment = (
  services: CodevisorServerServices,
  checkout: WorkspaceGitCheckout
): Promise<NodeJS.ProcessEnv> =>
  services.resolveGitEnvironment?.(checkout.directory) ?? Promise.resolve(process.env)

const checkoutHead = (checkout: WorkspaceGitCheckout, env: NodeJS.ProcessEnv): Promise<GitHead> => {
  if (checkout.branch === undefined) return gitHead(checkout.directory, env)
  return Promise.resolve({ branch: checkout.branch })
}

const isArchivedIn = (workspaces: ReadonlyArray<Workspace>, workspaceId: string): boolean =>
  workspaces.some((candidate) => isArchivedWorkspace(candidate, workspaceId))

const isArchivedWorkspace = (candidate: Workspace, workspaceId: string): boolean =>
  sameId(candidate.id, workspaceId) && candidate.isArchived

const isInWorkspace = (session: SessionSummary, workspaceId: string): boolean =>
  session.workspaceId?.toLowerCase() === workspaceId.toLowerCase()

const refuseBotDelete = (services: CodevisorServerServices, workspaceId: string): Promise<void> =>
  assertNotOwnedByBot(services, { workspaceId }, "delete this workspace")

const refuseBotArchive = (services: CodevisorServerServices, workspaceId: string): Promise<void> =>
  assertNotOwnedByBot(services, { workspaceId }, "archive this workspace")

const archiveWorkspace = (
  services: CodevisorServerServices,
  workspaceId: string
): Promise<Workspace> => run(services.db.updateWorkspace(workspaceId, { isArchived: true }))

const allSessions = (services: CodevisorServerServices): Promise<ReadonlyArray<SessionSummary>> =>
  run(services.db.listSessions)

const detachSession = (services: CodevisorServerServices, session: SessionSummary): Promise<void> =>
  run(services.db.setSessionWorkspace(session.id, null))

const applyArchiveEffects = (
  { services, fanout, config, routeState }: RouteContext,
  workspace: Workspace,
  wasArchived: boolean
): Promise<Workspace> =>
  applyWorkspaceArchiveEffects(services, fanout, config, routeState, workspace, wasArchived)

const publishWorkspaceUpdated = (
  { services, fanout }: RouteContext,
  workspace: Workspace
): Promise<EventEnvelope> =>
  appendAndPublish(services.db, fanout, "workspace.updated", workspace.id, workspace)

const publishWorkspaceDeleted = (
  { services, fanout }: RouteContext,
  workspaceId: string
): Promise<EventEnvelope> =>
  appendAndPublish(services.db, fanout, "workspace.deleted", workspaceId, { id: workspaceId })

const noContent = (response: ServerResponse): boolean => {
  writeJson(response, 204, undefined)
  return true
}
