import type { IncomingMessage, ServerResponse } from "node:http"

import type { UpdateMcpServerRequest } from "@codevisor/api"
import {
  CreateMcpServerRequest as CreateMcpServerRequestSchema,
  DetectMcpAuthRequest as DetectMcpAuthRequestSchema,
  ImportNativeMcpsRequest as ImportNativeMcpsRequestSchema,
  RemoveNativeMcpRequest as RemoveNativeMcpRequestSchema,
  SetNativeMcpEnabledRequest as SetNativeMcpEnabledRequestSchema,
  UpdateMcpServerRequest as UpdateMcpServerRequestSchema
} from "@codevisor/api"
import type { McpManager } from "@codevisor/mcp"

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

  const catalog = routeMcpCatalog(manager, request, response, url)
  if (catalog !== undefined) return catalog
  const action = routeMcpAction(manager, request, response, url)
  if (action !== undefined) return action
  const mutation = routeMcpMutation(manager, request, response, url)
  if (mutation !== undefined) return mutation
  return false
}

function routeMcpCatalog(
  manager: McpManager,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> | undefined {
  if (url.pathname === "/v1/mcps") {
    if (request.method === "GET") return listMcpServers(manager, response)
    if (request.method === "POST") return createMcpServer(manager, request, response)
  }
  if (url.pathname === "/v1/mcps/detect-auth" && request.method === "POST") {
    return detectMcpAuthorization(manager, request, response)
  }
  const toolsId = matchRoute(url.pathname, "/v1/mcps/:id/tools")
  if (toolsId !== undefined && request.method === "GET") {
    return listMcpTools(manager, response, toolsId)
  }
  return undefined
}

function routeMcpAction(
  manager: McpManager,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> | undefined {
  const action = matchRouteParams(url.pathname, "/v1/mcps/:id/:action")
  if (action !== undefined && request.method === "POST") {
    switch (action.action) {
      case "connect":
        return connectMcpServer(manager, response, action.id!)
      case "oauth-start":
        return beginMcpAuthorization(manager, response, action.id!, url)
      case "oauth-disconnect":
        return disconnectMcpAuthorization(manager, response, action.id!)
      default:
        break
    }
  }
  return undefined
}

function routeMcpMutation(
  manager: McpManager,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> | undefined {
  const id = matchRoute(url.pathname, "/v1/mcps/:id")
  if (id !== undefined) {
    if (request.method === "PATCH") return updateMcpServer(manager, request, response, id)
    if (request.method === "DELETE") return removeMcpServer(manager, response, id)
  }
  return undefined
}

async function listMcpServers(manager: McpManager, response: ServerResponse): Promise<boolean> {
  writeJson(response, 200, await manager.list())
  return true
}

async function listMcpTools(
  manager: McpManager,
  response: ServerResponse,
  id: string
): Promise<boolean> {
  writeJson(response, 200, await manager.tools(id))
  return true
}

async function connectMcpServer(
  manager: McpManager,
  response: ServerResponse,
  id: string
): Promise<boolean> {
  writeJson(response, 200, await manager.connect(id))
  return true
}

async function disconnectMcpAuthorization(
  manager: McpManager,
  response: ServerResponse,
  id: string
): Promise<boolean> {
  writeJson(response, 200, await manager.disconnectOAuth(id))
  return true
}

async function createMcpServer(
  manager: McpManager,
  request: IncomingMessage,
  response: ServerResponse
): Promise<boolean> {
  writeJson(
    response,
    201,
    await manager.create(await readSchema(request, CreateMcpServerRequestSchema))
  )
  return true
}

async function detectMcpAuthorization(
  manager: McpManager,
  request: IncomingMessage,
  response: ServerResponse
): Promise<boolean> {
  const payload = await readSchema(request, DetectMcpAuthRequestSchema)
  writeJson(response, 200, await manager.detectAuth(payload.url))
  return true
}

async function beginMcpAuthorization(
  manager: McpManager,
  response: ServerResponse,
  id: string,
  url: URL
): Promise<boolean> {
  writeJson(response, 201, {
    authorizationUrl: await manager.beginOAuth(id, url.origin)
  })
  return true
}

function validateMcpEdit(id: string, update: UpdateMcpServerRequest): void {
  if (["browser", "computer"].includes(id)) {
    const unsupported = Object.keys(update).filter((key) => key !== "enabled")
    if (unsupported.length > 0) {
      throw new HttpFailure(409, "Built-in automation providers can only be enabled or disabled")
    }
  }
}

async function updateMcpServer(
  manager: McpManager,
  request: IncomingMessage,
  response: ServerResponse,
  id: string
): Promise<boolean> {
  const update = await readSchema(request, UpdateMcpServerRequestSchema)
  validateMcpEdit(id, update)
  writeJson(response, 200, await manager.update(id, update))
  return true
}

async function removeMcpServer(
  manager: McpManager,
  response: ServerResponse,
  id: string
): Promise<boolean> {
  if (["browser", "computer"].includes(id)) {
    throw new HttpFailure(409, "Built-in automation providers cannot be removed")
  }
  await manager.remove(id)
  writeJson(response, 204, undefined)
  return true
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
