import type { IncomingMessage, ServerResponse } from "node:http"

import {
  CreateSkillRequest as CreateSkillRequestSchema,
  DiscoverRemoteSkillsRequest as DiscoverRemoteSkillsRequestSchema,
  ImportRemoteSkillRequest as ImportRemoteSkillRequestSchema,
  UpdateSkillRequest as UpdateSkillRequestSchema
} from "@codevisor/api"

import {
  HttpFailure,
  matchRoute,
  readSchema,
  writeJson,
  type CodevisorServerServices
} from "../server-context.js"

export const routeSkills = async (
  services: CodevisorServerServices,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  const manager = services.skills
  if (!url.pathname.startsWith("/v1/skills")) return false
  if (manager === undefined) throw new HttpFailure(501, "Skills management unavailable")

  if (url.pathname === "/v1/skills") {
    if (request.method === "GET") {
      writeJson(response, 200, await manager.list())
      return true
    }
    if (request.method === "POST") {
      writeJson(
        response,
        201,
        await manager.create(await readSchema(request, CreateSkillRequestSchema))
      )
      return true
    }
  }

  if (url.pathname === "/v1/skills/import-remote" && request.method === "POST") {
    writeJson(
      response,
      201,
      await manager.importRemote(await readSchema(request, ImportRemoteSkillRequestSchema))
    )
    return true
  }

  if (url.pathname === "/v1/skills/discover-remote" && request.method === "POST") {
    writeJson(
      response,
      200,
      await manager.discoverRemote(await readSchema(request, DiscoverRemoteSkillsRequestSchema))
    )
    return true
  }

  const name = matchRoute(url.pathname, "/v1/skills/:name")
  if (name !== undefined && request.method === "GET") {
    writeJson(response, 200, await manager.read(name))
    return true
  }
  if (name !== undefined && request.method === "PUT") {
    writeJson(
      response,
      200,
      await manager.update(name, await readSchema(request, UpdateSkillRequestSchema))
    )
    return true
  }
  if (name !== undefined && request.method === "DELETE") {
    writeJson(response, 200, await manager.remove(name))
    return true
  }
  return false
}
