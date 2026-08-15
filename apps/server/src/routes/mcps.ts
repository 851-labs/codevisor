import {
  CreateMcpServerRequest as CreateMcpServerRequestSchema,
  DetectMcpAuthRequest as DetectMcpAuthRequestSchema,
  ImportNativeMcpsRequest as ImportNativeMcpsRequestSchema,
  RemoveNativeMcpRequest as RemoveNativeMcpRequestSchema,
  SetNativeMcpEnabledRequest as SetNativeMcpEnabledRequestSchema,
  UpdateMcpServerRequest as UpdateMcpServerRequestSchema
} from "@codevisor/api"
import type { IncomingMessage, ServerResponse } from "node:http"
import {
  HttpFailure,
  matchRoute,
  matchRouteParams,
  readSchema,
  run,
  writeJson,
  type CodevisorServerServices
} from "../server-context.js"

export const routeMcps = async (
  services: CodevisorServerServices,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  const manager = services.mcp
  if (!url.pathname.startsWith("/v1/mcps")) return false
  if (manager === undefined) throw new HttpFailure(501, "MCP gateway unavailable")

  if (url.pathname === "/v1/mcps") {
    if (request.method === "GET") {
      writeJson(response, 200, await manager.list())
      return true
    }
    if (request.method === "POST") {
      writeJson(
        response,
        201,
        await manager.create(await readSchema(request, CreateMcpServerRequestSchema))
      )
      return true
    }
  }

  if (url.pathname === "/v1/mcps/detect-auth" && request.method === "POST") {
    const payload = await readSchema(request, DetectMcpAuthRequestSchema)
    writeJson(response, 200, await manager.detectAuth(payload.url))
    return true
  }

  const toolsId = matchRoute(url.pathname, "/v1/mcps/:id/tools")
  if (toolsId !== undefined && request.method === "GET") {
    writeJson(response, 200, await manager.tools(toolsId))
    return true
  }

  const action = matchRouteParams(url.pathname, "/v1/mcps/:id/:action")
  if (action !== undefined && request.method === "POST") {
    switch (action.action) {
      case "connect":
        writeJson(response, 200, await manager.connect(action.id!))
        return true
      case "oauth-start":
        writeJson(response, 201, {
          authorizationUrl: await manager.beginOAuth(action.id!, url.origin)
        })
        return true
      case "oauth-disconnect":
        writeJson(response, 200, await manager.disconnectOAuth(action.id!))
        return true
      default:
        break
    }
  }

  const id = matchRoute(url.pathname, "/v1/mcps/:id")
  if (id !== undefined) {
    if (request.method === "PATCH") {
      const update = await readSchema(request, UpdateMcpServerRequestSchema)
      if (["browser", "computer"].includes(id)) {
        const unsupported = Object.keys(update).filter((key) => key !== "enabled")
        if (unsupported.length > 0) {
          throw new HttpFailure(
            409,
            "Built-in automation providers can only be enabled or disabled"
          )
        }
      }
      writeJson(response, 200, await manager.update(id, update))
      return true
    }
    if (request.method === "DELETE") {
      if (["browser", "computer"].includes(id)) {
        throw new HttpFailure(409, "Built-in automation providers cannot be removed")
      }
      await manager.remove(id)
      writeJson(response, 204, undefined)
      return true
    }
  }
  return false
}

export const routeMcpScopes = async (
  services: CodevisorServerServices,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  const manager = services.mcp
  const projectRoute = matchRouteParams(url.pathname, "/v1/projects/:id/mcps/:mcpId")
  if (projectRoute !== undefined && request.method === "PATCH") {
    if (manager === undefined) throw new HttpFailure(501, "MCP gateway unavailable")
    const payload = await readSchema(request, UpdateMcpServerRequestSchema)
    if (payload.enabled === undefined) throw new HttpFailure(400, "enabled is required")
    writeJson(
      response,
      200,
      await manager.setProjectEnabled(projectRoute.id!, projectRoute.mcpId!, payload.enabled)
    )
    return true
  }
  const sessionRoute = matchRouteParams(url.pathname, "/v1/sessions/:id/mcps/:mcpId")
  if (sessionRoute !== undefined && request.method === "PATCH") {
    if (manager === undefined) throw new HttpFailure(501, "MCP gateway unavailable")
    const payload = await readSchema(request, UpdateMcpServerRequestSchema)
    if (payload.enabled === undefined) throw new HttpFailure(400, "enabled is required")
    const session = await run(services.db.getSessionSummary(sessionRoute.id!))
    writeJson(
      response,
      200,
      await manager.setSessionEnabled(
        session.id,
        sessionRoute.mcpId!,
        payload.enabled,
        session.projectId
      )
    )
    return true
  }
  return false
}

export const routeNativeMcps = async (
  services: CodevisorServerServices,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  const manager = services.nativeMcp
  if (!url.pathname.startsWith("/v1/native-mcps")) return false
  if (manager === undefined) throw new HttpFailure(501, "Native MCP discovery unavailable")

  if (url.pathname === "/v1/native-mcps" && request.method === "GET") {
    writeJson(response, 200, await manager.scan())
    return true
  }

  if (url.pathname === "/v1/native-mcps/import" && request.method === "POST") {
    writeJson(
      response,
      200,
      await manager.importServers(await readSchema(request, ImportNativeMcpsRequestSchema))
    )
    return true
  }

  if (url.pathname === "/v1/native-mcps/remove" && request.method === "POST") {
    const payload = await readSchema(request, RemoveNativeMcpRequestSchema)
    writeJson(response, 200, await manager.removeServer(payload.harnessId, payload.serverName))
    return true
  }

  if (url.pathname === "/v1/native-mcps/removals" && request.method === "GET") {
    writeJson(response, 200, await manager.listRemovals())
    return true
  }

  const removalRoute = matchRouteParams(url.pathname, "/v1/native-mcps/removals/:id/:action")
  if (
    removalRoute !== undefined &&
    removalRoute.action === "restore" &&
    request.method === "POST"
  ) {
    writeJson(response, 200, await manager.restoreRemoval(removalRoute.id!))
    return true
  }

  if (url.pathname === "/v1/native-mcps/set-enabled" && request.method === "POST") {
    const payload = await readSchema(request, SetNativeMcpEnabledRequestSchema)
    writeJson(
      response,
      200,
      await manager.setNativeEnabled(payload.harnessId, payload.serverName, payload.enabled)
    )
    return true
  }
  return false
}
