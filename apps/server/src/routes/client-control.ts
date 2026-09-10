import { ClientNavigationRequest } from "@codevisor/api"
import type { IncomingMessage, ServerResponse } from "node:http"
import { HttpFailure, matchRouteParams, readSchema, writeJson } from "../server-context.js"
import type { ClientControlBroker } from "../infra/client-control.js"

export const routeClientControl = async (
  broker: ClientControlBroker | undefined,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (!url.pathname.startsWith("/v1/clients")) return false
  if (!broker) throw new HttpFailure(501, "Client control unavailable")
  if (url.pathname === "/v1/clients" && request.method === "GET") {
    writeJson(response, 200, broker.list())
    return true
  }
  const route = matchRouteParams(url.pathname, "/v1/clients/:clientId/:action")
  if (!route) return false
  if (route.action === "context" && request.method === "GET") {
    writeJson(response, 200, await broker.request(route.clientId!, { method: "context" }))
    return true
  }
  if (route.action === "navigate" && request.method === "POST") {
    const navigation = await readSchema(request, ClientNavigationRequest)
    writeJson(
      response,
      200,
      await broker.request(route.clientId!, { method: "navigate", navigation })
    )
    return true
  }
  return false
}
