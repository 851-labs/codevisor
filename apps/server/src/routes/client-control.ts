import type { IncomingMessage, ServerResponse } from "node:http"

import {
  ClientNavigationRequest,
  ClientPageRequest,
  ClientLayoutRequest,
  ClientWindowRequest
} from "@codevisor/api"

import type { ClientControlBroker } from "../infra/client-control.js"
import {
  HttpFailure,
  matchRouteParams,
  readSchema,
  run,
  writeJson,
  type CodevisorServerServices
} from "../server-context.js"

export const routeClientControl = async (
  broker: ClientControlBroker,
  services: CodevisorServerServices,
  machine: { readonly id: string; readonly name: string },
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (!url.pathname.startsWith("/v1/clients")) return false
  if (url.pathname === "/v1/clients" && request.method === "GET") {
    writeJson(response, 200, await broker.describe(machine, url.searchParams.get("originClientId")))
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
  if (route.action === "page" && request.method === "POST") {
    const page = await readSchema(request, ClientPageRequest)
    writeJson(response, 200, await broker.request(route.clientId!, { method: "page", page }))
    return true
  }
  if (route.action === "layout" && request.method === "POST") {
    const layout = await readSchema(request, ClientLayoutRequest)
    await refuseTabsInBotConversation(services, layout)
    writeJson(response, 200, await broker.request(route.clientId!, { method: "layout", layout }))
    return true
  }
  if (route.action === "window" && request.method === "POST") {
    const window = await readSchema(request, ClientWindowRequest)
    writeJson(response, 200, await broker.request(route.clientId!, { method: "window", window }))
    return true
  }
  return false
}

const splitsOnlyRefusals: Readonly<Record<string, string>> = {
  new_tab: "Bot conversations show splits only; use split instead of new_tab.",
  detach: "Bot conversations show splits only; use move to rearrange the pane instead of detach.",
  reorder_tabs: "Bot conversations show splits only, so there are no tabs to reorder."
}

const refuseTabsInBotConversation = async (
  services: CodevisorServerServices,
  layout: ClientLayoutRequest
): Promise<void> => {
  const refusal = splitsOnlyRefusals[layout.action.kind]
  if (refusal === undefined) return

  const bot = await run(services.db.findBotOwning({ workspaceId: layout.workspaceId }))
  if (bot !== undefined) throw new HttpFailure(409, refusal)
}
