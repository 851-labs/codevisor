import type { IncomingMessage, ServerResponse } from "node:http"

import { HttpFailure, writeJson, type CodevisorServerServices } from "../server-context.js"

export const routeLinkPreviews = async (
  services: CodevisorServerServices,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (url.pathname !== "/v1/link-previews" && url.pathname !== "/v1/link-previews/image")
    return false
  if (request.method !== "GET") return false
  const store = services.linkPreviews
  if (store === undefined) throw new HttpFailure(501, "Link previews unavailable")
  const target = url.searchParams.get("url")
  if (target === null) throw new HttpFailure(400, "url is required")
  if (url.pathname === "/v1/link-previews") {
    const preview = await store.preview(target)
    if (preview === undefined) throw new HttpFailure(404, "No preview")
    writeJson(response, 200, preview)
    return true
  }
  const image = await store.image(target)
  if (image === undefined) throw new HttpFailure(404, "No preview image")
  response.writeHead(200, {
    "Cache-Control": "private, max-age=86400",
    "Content-Length": String(image.data.byteLength),
    "Content-Type": image.contentType
  })
  response.end(image.data)
  return true
}
