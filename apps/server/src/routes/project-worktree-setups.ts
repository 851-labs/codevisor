import type { IncomingMessage, ServerResponse } from "node:http"
import type { URL } from "node:url"

import { StartWorktreeSetupRequest } from "@codevisor/api"

import {
  matchRoute,
  matchRouteParams,
  readSchema,
  writeJson,
  type CodevisorServerConfig,
  type CodevisorServerServices,
  type EventFanout
} from "../server-context.js"
import { startWorktreeSetup, worktreeSetupStatus } from "./worktree-setup-jobs.js"

export interface WorktreeSetupRoute {
  readonly services: CodevisorServerServices
  readonly config: CodevisorServerConfig
  readonly fanout: EventFanout
  readonly serverId: string
  readonly request: IncomingMessage
  readonly response: ServerResponse
  readonly url: URL
}

export const routeWorktreeSetups = (route: WorktreeSetupRoute): Promise<boolean> | undefined => {
  const { request, url } = route
  const startProjectId = matchRoute(url.pathname, "/v1/projects/:id/worktree-setups")
  if (startProjectId !== undefined && request.method === "POST")
    return startSetup(route, startProjectId)

  const statusRoute = matchRouteParams(url.pathname, "/v1/projects/:id/worktree-setups/:worktreeId")
  if (statusRoute !== undefined && request.method === "GET")
    return readStatus(route, statusRoute["id"]!, statusRoute["worktreeId"]!)
  return undefined
}

const startSetup = async (route: WorktreeSetupRoute, projectId: string): Promise<boolean> => {
  const payload = await readSchema(route.request, StartWorktreeSetupRequest)
  const status = await startWorktreeSetup(route, projectId, payload)
  writeJson(route.response, 202, status)
  return true
}

const readStatus = async (
  route: WorktreeSetupRoute,
  projectId: string,
  worktreeId: string
): Promise<boolean> => {
  writeJson(route.response, 200, await worktreeSetupStatus(route.services, projectId, worktreeId))
  return true
}
