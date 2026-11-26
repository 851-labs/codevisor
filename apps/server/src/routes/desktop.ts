import type { DesktopStatus } from "@codevisor/api"

import type { DesktopManager } from "../desktop/desktop-manager.js"
import { HttpFailure, writeJson } from "../server-context.js"
import { appendAndPublish } from "../server-http.js"
import type { RouteContext } from "./route-context.js"

type DesktopAction = (desktop: DesktopManager, url: URL) => Promise<DesktopStatus>

const actions: Readonly<Record<string, DesktopAction>> = {
  "GET /v1/desktop": (desktop) => desktop.status(),
  "POST /v1/desktop/packages": (desktop) => desktop.installPackages(),
  "POST /v1/desktop/replace-old": (desktop) => desktop.replaceOld(),
  "POST /v1/desktop/start": (desktop, url) =>
    desktop.start({ replaceUnmanaged: url.searchParams.get("replace") === "1" }),
  "DELETE /v1/desktop": (desktop, url) =>
    desktop.remove({ unshareUnmanaged: url.searchParams.get("unshare") === "1" })
}

const changesWhatIsShared = new Set(["POST /v1/desktop/start", "DELETE /v1/desktop"])

export const routeDesktop = async (route: RouteContext): Promise<boolean> => {
  const { request, response, url, config } = route
  const endpoint = `${request.method} ${url.pathname}`
  const action = actions[endpoint]
  if (action === undefined) return false
  if (request.headers.origin !== undefined || request.headers["sec-fetch-site"] !== undefined)
    throw new HttpFailure(403, "Native clients only")
  if (config.desktop === undefined)
    throw new HttpFailure(501, "A desktop can only be set up on a Linux machine")

  response.setHeader("Cache-Control", "no-store")
  try {
    writeJson(response, 200, await action(config.desktop, url))
  } finally {
    if (changesWhatIsShared.has(endpoint)) announceFeatures(route)
  }
  return true
}

const announceFeatures = ({ services, fanout }: RouteContext): void => {
  void appendAndPublish(services.db, fanout, "server.features.updated", "server", {}).catch(
    () => undefined
  )
}
