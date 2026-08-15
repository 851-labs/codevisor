import {
  CreateSkillRequest as CreateSkillRequestSchema,
  DiscoverRemoteSkillsRequest as DiscoverRemoteSkillsRequestSchema,
  ImportRemoteSkillRequest as ImportRemoteSkillRequestSchema,
  ImportSkillRequest as ImportSkillRequestSchema,
  MakeSkillGlobalRequest as MakeSkillGlobalRequestSchema,
  SetSkillInstalledRequest as SetSkillInstalledRequestSchema,
  SyncSkillsRequest as SyncSkillsRequestSchema
} from "@codevisor/api"
import type { IncomingMessage, ServerResponse } from "node:http"
import {
  HttpFailure,
  matchRoute,
  matchRouteParams,
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

  if (url.pathname === "/v1/skills/import" && request.method === "POST") {
    writeJson(
      response,
      201,
      await manager.importLocal(await readSchema(request, ImportSkillRequestSchema))
    )
    return true
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

  if (url.pathname === "/v1/skills/make-global" && request.method === "POST") {
    const payload = await readSchema(request, MakeSkillGlobalRequestSchema)
    writeJson(response, 200, await manager.makeGlobal(payload.harnessId, payload.directoryName))
    return true
  }

  if (url.pathname === "/v1/skills/sync" && request.method === "POST") {
    writeJson(response, 200, await manager.sync(await readSchema(request, SyncSkillsRequestSchema)))
    return true
  }

  const installRoute = matchRouteParams(url.pathname, "/v1/skills/:name/harnesses/:harnessId")
  if (installRoute !== undefined && request.method === "PUT") {
    const payload = await readSchema(request, SetSkillInstalledRequestSchema)
    writeJson(
      response,
      200,
      await manager.setInstalled(installRoute.name!, installRoute.harnessId!, payload.installed)
    )
    return true
  }

  const name = matchRoute(url.pathname, "/v1/skills/:name")
  if (name !== undefined && request.method === "DELETE") {
    writeJson(response, 200, await manager.remove(name))
    return true
  }
  return false
}
