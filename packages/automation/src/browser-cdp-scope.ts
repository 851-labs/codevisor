import type { BrowserRuntime, PageHandle } from "./browser-cdp-engine.js"
import { tabSessionIds } from "./browser-frame-sessions.js"
import { isPlainRecord } from "./unknown-values.js"

type CdpParams = Readonly<Record<string, unknown>>
type TabScope = Pick<BrowserRuntime, "sessions" | "frameParents" | "staleSessions">

export const requireTabScopedCommand = (
  runtime: TabScope,
  page: PageHandle,
  method: string,
  params: CdpParams
): void => {
  if (browserWideCommands.has(method)) throw new Error(browserWide(method))
  if (sessionCommands.has(method)) throw new Error(managedSessions(method))
  if (!method.startsWith("Target.")) return

  if (typeof params.targetId === "string") requireTabTarget(runtime, page, params.targetId)
}

export const tabScopedSession = (runtime: TabScope, page: PageHandle, target: unknown): string => {
  const wanted = wantedTarget(target)
  if (wanted === undefined) return page.sessionId

  const sessionId = liveSession(runtime, page, wanted)
  if (sessionId === undefined) throw new Error(outsideTab(wanted))
  return sessionId
}

export const tabScopedEventSession = (
  runtime: TabScope,
  page: PageHandle,
  target: unknown
): string => {
  const wanted = wantedTarget(target)
  if (wanted === undefined) return page.sessionId

  const sessionId = liveSession(runtime, page, wanted) ?? closedSession(runtime, page, wanted)
  if (sessionId === undefined) throw new Error(outsideTab(wanted))
  return sessionId
}

export const tabScopedResult = (
  runtime: TabScope,
  page: PageHandle,
  method: string,
  result: unknown
): unknown => {
  if (method !== "Target.getTargets" || !isPlainRecord(result)) return result
  if (!Array.isArray(result.targetInfos)) return result

  const own = new Set(tabTargetIds(runtime, page))
  const targetInfos: unknown[] = result.targetInfos
  return {
    ...result,
    targetInfos: targetInfos.filter(
      (info) => isPlainRecord(info) && typeof info.targetId === "string" && own.has(info.targetId)
    )
  }
}

const browserWideCommands = new Set([
  "Browser.close",
  "Browser.crash",
  "Browser.crashGpuProcess",
  "Target.attachToBrowserTarget",
  "Target.createBrowserContext",
  "Target.createTarget",
  "Target.disposeBrowserContext",
  "Target.getBrowserContexts",
  "Target.setDiscoverTargets",
  "Target.setRemoteLocations"
])

const sessionCommands = new Set([
  "Target.attachToTarget",
  "Target.autoAttachRelated",
  "Target.detachFromTarget",
  "Target.exposeDevToolsProtocol",
  "Target.sendMessageToTarget",
  "Target.setAutoAttach"
])

const browserWide = (method: string): string =>
  `${method} acts on the whole browser, not this tab, so a tab can't send it. Open, select and close tabs with browser.tabs.`

const managedSessions = (method: string): string =>
  `${method} isn't available: Codevisor attaches to this tab and its frames itself. Reach a cross-site frame by passing its id as the target option of send.`

const outsideTab = (wanted: string): string =>
  `"${wanted}" isn't this tab or one of its cross-site frames, so nothing was sent. A same-site frame shares the tab's session: send to the tab and name the frame in the command, for example Page.createIsolatedWorld({ frameId }) then Runtime.evaluate({ contextId }).`

const malformedTarget =
  "target must be a frame or target id, or an object with targetId, frameId or sessionId."

const wantedTarget = (target: unknown): string | undefined => {
  if (target === undefined || target === null) return undefined
  if (typeof target === "string") return target

  const named = isPlainRecord(target)
    ? (target.sessionId ?? target.targetId ?? target.frameId)
    : undefined
  if (typeof named !== "string") throw new Error(malformedTarget)
  return named
}

const liveSession = (runtime: TabScope, page: PageHandle, wanted: string): string | undefined => {
  const sessions = tabSessionIds(runtime, page.sessionId)
  if (sessions.includes(wanted)) return wanted
  if (wanted === page.target.targetId) return page.sessionId

  const sessionId = runtime.sessions.get(wanted)
  if (sessionId !== undefined && sessions.includes(sessionId)) return sessionId
  return undefined
}

const closedSession = (runtime: TabScope, page: PageHandle, wanted: string): string | undefined =>
  runtime.staleSessions.get(wanted) === page.target.targetId ? wanted : undefined

const tabTargetIds = (runtime: TabScope, page: PageHandle): string[] => {
  const sessions = new Set(tabSessionIds(runtime, page.sessionId))
  const frames = [...runtime.sessions]
    .filter(([, sessionId]) => sessions.has(sessionId))
    .map(([targetId]) => targetId)
  return [page.target.targetId, ...frames]
}

const requireTabTarget = (runtime: TabScope, page: PageHandle, targetId: string): void => {
  if (!tabTargetIds(runtime, page).includes(targetId)) throw new Error(outsideTab(targetId))
}
