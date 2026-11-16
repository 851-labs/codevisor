import {
  evaluate,
  pageInformation,
  waitForReady,
  type BrowserRuntime,
  type PageHandle
} from "./browser-cdp-engine.js"
import { delay } from "./browser-cdp.js"
import {
  busyNetworkHint,
  networkIsQuiet,
  newNetworkActivity,
  observeNetworkActivity,
  type NetworkActivity
} from "./browser-network-activity.js"
import { waitBudget } from "./browser-wait-budget.js"
import { recordOrUndefined } from "./unknown-values.js"

const loads = new WeakMap<BrowserRuntime, Map<string, NetworkActivity>>()
const loadFor = (runtime: BrowserRuntime, session: string) => {
  let sessions = loads.get(runtime)
  if (!sessions) {
    sessions = new Map()
    loads.set(runtime, sessions)
  }
  let activity = sessions.get(session)
  if (!activity) {
    activity = newNetworkActivity(performance.now())
    sessions.set(session, activity)
  }
  return activity
}

export const observeBrowserLoadEvent = (
  runtime: BrowserRuntime,
  method: string,
  params: Readonly<Record<string, unknown>>,
  session?: string
): void => {
  if (!session) return
  observeNetworkActivity(loadFor(runtime, session), method, params, performance.now())
  if (method === "Page.frameNavigated" || method === "Page.navigatedWithinDocument") {
    const target = [...runtime.sessions].find(([, id]) => id === session)?.[0]
    if (target)
      for (const key of runtime.snapshots.keys())
        if (key === target || key.endsWith(`:${target}`)) runtime.snapshots.delete(key)
  }
}

export const browserNavigationBaseline = async (runtime: BrowserRuntime, page: PageHandle) => {
  const tree = await runtime.connection.send<{ frameTree: { frame: { id: string } } }>(
    "Page.getFrameTree",
    {},
    page.sessionId
  )
  return { afterSequence: runtime.eventSequence, frameId: tree.frameTree.frame.id }
}

export const waitForBrowserState = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  options: {
    state?: string
    url?: string
    timeoutMs?: number
    afterSequence?: number
    frameId?: string
  }
): Promise<void> => {
  const state = options.state ?? "load"
  if (!["commit", "domcontentloaded", "load", "networkidle"].includes(state))
    throw new Error("Unsupported browser load state")
  const deadline = performance.now() + waitBudget(options.timeoutMs)
  while (true) {
    const navigated =
      options.afterSequence === undefined ||
      runtime.eventLog.some((event) => {
        if (event.sequence <= options.afterSequence! || event.sessionId !== page.sessionId)
          return false
        if (event.method === "Page.navigatedWithinDocument")
          return event.params.frameId === options.frameId
        return (
          event.method === "Page.frameNavigated" &&
          recordOrUndefined(event.params.frame)?.id === options.frameId
        )
      })
    const matchesUrl =
      options.url === undefined || (await pageInformation(runtime, page)).url === options.url
    if (navigated && matchesUrl) {
      let ready: unknown
      if (state === "commit") ready = "complete"
      else ready = await evaluate(runtime, page, "document.readyState")
      const documentReady =
        ready === "complete" || (state === "domcontentloaded" && ready === "interactive")
      const quiet =
        state !== "networkidle" ||
        networkIsQuiet(loadFor(runtime, page.sessionId), performance.now())
      if (documentReady && quiet) return
    }
    if (performance.now() >= deadline)
      throw new Error(
        `Timed out waiting for ${options.afterSequence === undefined ? "page" : "navigation"} ${state}${options.url ? ` at ${options.url}` : ""}${state === "networkidle" ? busyNetworkHint(loadFor(runtime, page.sessionId)) : ""}`
      )
    await delay(Math.min(50, Math.max(1, deadline - performance.now())))
  }
}

const leavePageWaitMs = 15_000

export const waitForMainFrameNavigation = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  afterSequence: number
): Promise<void> => {
  const deadline = performance.now() + leavePageWaitMs
  while (!mainFrameNavigatedSince(runtime, page, afterSequence)) {
    if (performance.now() >= deadline) return
    await delay(50)
  }
  await waitForReady(runtime, page).catch(() => undefined)
}

const mainFrameNavigatedSince = (
  runtime: BrowserRuntime,
  page: PageHandle,
  afterSequence: number
): boolean =>
  runtime.eventLog.some(
    (event) =>
      event.sequence > afterSequence &&
      event.sessionId === page.sessionId &&
      event.method === "Page.frameNavigated" &&
      recordOrUndefined(event.params.frame)?.parentId === undefined
  )
