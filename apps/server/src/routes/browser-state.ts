import { BrowserCookieExchange, BrowserNavigation } from "@codevisor/api"
import type { IncomingMessage, ServerResponse } from "node:http"
import {
  HttpFailure,
  readSchema,
  run,
  writeJson,
  type CodevisorServerServices
} from "../server-context.js"

export const routeBrowserState = async (
  services: CodevisorServerServices,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (!url.pathname.startsWith("/v1/browser/state/")) return false
  // Called after pairing authentication. Websites cannot use the loopback exception.
  if (request.headers.origin !== undefined || request.headers["sec-fetch-site"] !== undefined)
    throw new HttpFailure(403, "Native clients only")
  response.setHeader("Cache-Control", "no-store")
  if (url.pathname === "/v1/browser/state/cookies" && request.method === "POST") {
    const { mutations } = await readSchema(request, BrowserCookieExchange)
    writeJson(response, 200, await run(services.db.exchangeBrowserCookies(mutations)))
    return true
  }
  const match = /^\/v1\/browser\/state\/panes\/([a-zA-Z0-9-]{1,80})$/.exec(url.pathname)
  if (match) {
    const paneId = match[1]!.toLowerCase()
    if (request.method === "PUT") {
      await run(
        services.db.setBrowserNavigation(paneId, await readSchema(request, BrowserNavigation))
      )
      writeJson(response, 200, {})
      return true
    }
    if (request.method === "GET") {
      writeJson(response, 200, {
        navigation: (await run(services.db.getBrowserNavigation(paneId))) ?? null
      })
      return true
    }
  }
  throw new HttpFailure(404, "Browser state route not found")
}
