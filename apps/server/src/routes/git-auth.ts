import type { IncomingMessage, ServerResponse } from "node:http"

import { StartGitAuthRequest as StartGitAuthRequestSchema } from "@codevisor/api"

import { makeGitAuthManager, type GitAuthManager } from "../infra/git-auth.js"
import { gitHostsOf } from "../infra/git-hosts.js"
import {
  failureMessage,
  HttpFailure,
  matchRoute,
  readSchema,
  writeJson,
  type CodevisorServerServices
} from "../server-context.js"
import { gitEnvironment } from "./project-setup-source.js"

const managers = new WeakMap<CodevisorServerServices, GitAuthManager>()

const managerFor = (services: CodevisorServerServices): GitAuthManager => {
  const manager =
    managers.get(services) ??
    makeGitAuthManager(() => gitEnvironment(services), gitHostsOf(services))
  managers.set(services, manager)
  return manager
}

export const routeGitAuth = async (
  services: CodevisorServerServices,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (!url.pathname.startsWith("/v1/git/auth/")) return false
  const manager = managerFor(services)
  if (request.method === "GET" && url.pathname === "/v1/git/auth/status") {
    const host = url.searchParams.get("host")?.trim()
    if (host === undefined || host.length === 0) throw new HttpFailure(400, "Missing host")
    writeJson(response, 200, await manager.status(host))
    return true
  }
  if (request.method === "POST" && url.pathname === "/v1/git/auth/login") {
    const payload = await readSchema(request, StartGitAuthRequestSchema)
    const flow = await manager.begin(payload.host).catch((cause: unknown) => {
      throw new HttpFailure(400, failureMessage(cause))
    })
    writeJson(response, 201, flow)
    return true
  }
  const flowId = matchRoute(url.pathname, "/v1/git/auth/login/:flowId")
  if (flowId === undefined) return false
  if (request.method === "GET") {
    const flow = manager.flow(flowId)
    if (flow === undefined) throw new HttpFailure(404, `Sign-in not found: ${flowId}`)
    writeJson(response, 200, flow)
    return true
  }
  if (request.method === "DELETE") {
    if (!manager.cancel(flowId)) throw new HttpFailure(404, `Sign-in not found: ${flowId}`)
    response.writeHead(204).end()
    return true
  }
  return false
}
