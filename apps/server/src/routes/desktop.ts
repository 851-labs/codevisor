import type { DesktopStatus } from "@codevisor/api"

import type { DesktopManager } from "../desktop/desktop-manager.js"
import type { ScreenShare } from "../desktop/screen-share.js"
import { HttpFailure, writeJson } from "../server-context.js"
import { appendAndPublish } from "../server-http.js"
import type { RouteContext } from "./route-context.js"

interface Desktops {
  readonly desktop: DesktopManager
  readonly screen: ScreenShare | undefined
}

type DesktopAction = (desktops: Desktops, url: URL) => Promise<DesktopStatus>

const actions: Readonly<Record<string, DesktopAction>> = {
  "GET /v1/desktop": ({ desktop }) => desktop.status(),
  "POST /v1/desktop/packages": ({ desktop }) => desktop.installPackages(),
  "POST /v1/desktop/replace-old": ({ desktop }) => desktop.replaceOld(),
  "POST /v1/desktop/start": ({ desktop }, url) =>
    desktop.start({ replaceUnmanaged: url.searchParams.get("replace") === "1" }),
  "DELETE /v1/desktop": ({ desktop }, url) =>
    desktop.remove({ unshareUnmanaged: url.searchParams.get("unshare") === "1" }),
  "POST /v1/desktop/screen": (desktops) => afterTheScreen(desktops, (screen) => screen.setUp()),
  "POST /v1/desktop/screen/packages": (desktops) =>
    afterTheScreen(desktops, (screen) => screen.installPackages()),
  "DELETE /v1/desktop/screen": (desktops) => afterTheScreen(desktops, (screen) => screen.remove())
}

const changesWhatIsShared = new Set([
  "POST /v1/desktop/start",
  "DELETE /v1/desktop",
  "POST /v1/desktop/screen",
  "DELETE /v1/desktop/screen"
])

export const routeDesktop = async (route: RouteContext): Promise<boolean> => {
  const { request, response, url, config } = route
  const endpoint = `${request.method} ${url.pathname}`
  const action = actions[endpoint]
  if (action === undefined) return false
  if (request.headers.origin !== undefined || request.headers["sec-fetch-site"] !== undefined)
    throw new HttpFailure(403, "Native clients only")
  if (config.desktop === undefined)
    throw new HttpFailure(501, "A desktop can only be set up on a Linux machine")

  const desktops = { desktop: config.desktop, screen: config.screen }
  response.setHeader("Cache-Control", "no-store")
  try {
    writeJson(response, 200, await withTheScreen(desktops, await action(desktops, url)))
  } finally {
    if (changesWhatIsShared.has(endpoint)) announceFeatures(route)
  }
  return true
}

const afterTheScreen = async (
  { desktop, screen }: Desktops,
  change: (screen: ScreenShare) => Promise<unknown>
): Promise<DesktopStatus> => {
  if (screen === undefined)
    throw new HttpFailure(501, "This server can't share the machine's screen")

  await change(screen)
  return desktop.status()
}

const withTheScreen = async (
  { screen }: Desktops,
  status: DesktopStatus
): Promise<DesktopStatus> => {
  if (screen === undefined) return status

  return { ...status, screen: await screen.status() }
}

const announceFeatures = ({ services, fanout }: RouteContext): void => {
  void appendAndPublish(services.db, fanout, "server.features.updated", "server", {}).catch(
    () => undefined
  )
}
