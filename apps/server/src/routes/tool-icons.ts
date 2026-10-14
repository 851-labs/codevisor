import type { IncomingMessage, ServerResponse } from "node:http"

import type { ToolIconAsset } from "../infra/tool-icons.js"
import { HttpFailure, matchRoute, type CodevisorServerServices } from "../server-context.js"

export const routeToolIcons = async (
  services: CodevisorServerServices,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (!url.pathname.startsWith("/v1/tool-icons/") || request.method !== "GET") return false
  const store = services.toolIcons
  if (store === undefined) throw new HttpFailure(501, "Tool icons unavailable")

  const theme = url.searchParams.get("theme") === "dark" ? "dark" : "light"
  let icon: ToolIconAsset | undefined
  if (url.pathname === "/v1/tool-icons/site") {
    const origin = url.searchParams.get("origin")
    if (origin === null) throw new HttpFailure(400, "origin is required")
    icon = await store.site(origin, theme)
  } else if (url.pathname === "/v1/tool-icons/app") {
    const bundleId = url.searchParams.get("bundleId")
    if (bundleId === null) throw new HttpFailure(400, "bundleId is required")
    icon = await store.app(bundleId, url.searchParams.get("path") ?? undefined)
  } else {
    const serverId = matchRoute(url.pathname, "/v1/tool-icons/mcp/:id")
    if (serverId === undefined) return false
    icon = await store.mcp(serverId, url.searchParams.get("host") ?? undefined, theme)
  }
  if (icon === undefined) throw new HttpFailure(404, "No icon")
  response.writeHead(200, {
    "Cache-Control": "private, max-age=86400",
    "Content-Length": String(icon.data.byteLength),
    "Content-Type": icon.contentType
  })
  response.end(icon.data)
  return true
}
