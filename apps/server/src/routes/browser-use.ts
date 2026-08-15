import { UpdateBrowserUseConfigurationRequest as UpdateBrowserUseConfigurationRequestSchema } from "@codevisor/api"
import { readFileSync } from "node:fs"
import type { IncomingMessage, ServerResponse } from "node:http"
import {
  HttpFailure,
  readSchema,
  writeJson,
  type CodevisorServerServices
} from "../server-context.js"

/* v8 ignore start -- browser setup routes are exercised by native app integration tests. */
export const routeBrowserUse = async (
  services: CodevisorServerServices,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (!url.pathname.startsWith("/v1/browser-use")) return false
  const manager = services.mcp
  if (manager === undefined) throw new HttpFailure(501, "Browser Use is unavailable")
  if (url.pathname === "/v1/browser-use" && request.method === "GET") {
    writeJson(response, 200, await manager.browserConfiguration())
    return true
  }
  if (url.pathname === "/v1/browser-use" && request.method === "PATCH") {
    const payload = await readSchema(request, UpdateBrowserUseConfigurationRequestSchema)
    writeJson(
      response,
      200,
      await manager.setBrowserPreference(payload.preferredBrowser ?? undefined)
    )
    return true
  }
  if (url.pathname === "/v1/browser-use/extension/install" && request.method === "POST") {
    writeJson(response, 200, await manager.openBrowserExtensionInstaller())
    return true
  }
  if (url.pathname === "/v1/browser-use/extension/folder" && request.method === "POST") {
    writeJson(response, 200, await manager.openBrowserExtensionFolder())
    return true
  }
  if (url.pathname === "/v1/browser-use/extension/chrome" && request.method === "POST") {
    writeJson(response, 200, await manager.openBrowserExtensionsPage())
    return true
  }
  if (url.pathname === "/v1/browser-use/extension/archive" && request.method === "GET") {
    const archive = readFileSync(manager.browserExtensionArchive())
    response.writeHead(200, {
      "Cache-Control": "no-store",
      "Content-Disposition": 'attachment; filename="Codevisor Chrome Extension.zip"',
      "Content-Length": archive.length,
      "Content-Type": "application/zip"
    })
    response.end(archive)
    return true
  }
  if (url.pathname === "/v1/browser-use/extension/icon" && request.method === "GET") {
    const icon = readFileSync(manager.browserExtensionIcon())
    response.writeHead(200, {
      "Cache-Control": "no-store",
      "Content-Length": icon.length,
      "Content-Type": "image/png"
    })
    response.end(icon)
    return true
  }
  if (url.pathname === "/v1/browser-use/extension/web-store" && request.method === "POST") {
    writeJson(response, 200, await manager.openBrowserExtensionWebStore())
    return true
  }
  throw new HttpFailure(404, "Browser Use route not found")
}
/* v8 ignore stop */
