import { delay } from "./browser-cdp.js"
import {
  evaluate,
  pageInformation,
  type BrowserRuntime,
  type PageHandle
} from "./browser-cdp-engine.js"

const loads = new WeakMap<
  BrowserRuntime,
  Map<string, { requests: Set<string>; changedAt: number }>
>()
const loadFor = (runtime: BrowserRuntime, session: string) => {
  let sessions = loads.get(runtime)
  if (!sessions) {
    sessions = new Map()
    loads.set(runtime, sessions)
  }
  let state = sessions.get(session)
  if (!state) {
    state = { requests: new Set(), changedAt: Date.now() }
    sessions.set(session, state)
  }
  return state
}

export const observeBrowserLoadEvent = (
  runtime: BrowserRuntime,
  method: string,
  params: Readonly<Record<string, unknown>>,
  session?: string
): void => {
  if (!session) return
  const state = loadFor(runtime, session)
  if (
    method === "Network.requestWillBeSent" &&
    params.type !== "WebSocket" &&
    params.type !== "EventSource"
  ) {
    state.requests.add(String(params.requestId))
    state.changedAt = Date.now()
  } else if (method === "Network.loadingFinished" || method === "Network.loadingFailed") {
    state.requests.delete(String(params.requestId))
    state.changedAt = Date.now()
  }
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
  const deadline = Date.now() + Math.max(0, Math.min(30_000, options.timeoutMs ?? 30_000))
  while (true) {
    const navigated =
      options.afterSequence === undefined ||
      runtime.eventLog.some((event) => {
        if (event.sequence <= options.afterSequence! || event.sessionId !== page.sessionId)
          return false
        if (event.method === "Page.navigatedWithinDocument")
          return event.params.frameId === options.frameId
        const frame = event.params.frame as { id?: string } | undefined
        return event.method === "Page.frameNavigated" && frame?.id === options.frameId
      })
    const matchesUrl =
      options.url === undefined || (await pageInformation(runtime, page)).url === options.url
    if (navigated && matchesUrl) {
      const ready =
        state === "commit"
          ? "complete"
          : await evaluate<string>(runtime, page, "document.readyState")
      const documentReady =
        ready === "complete" || (state === "domcontentloaded" && ready === "interactive")
      const network = loadFor(runtime, page.sessionId)
      if (
        documentReady &&
        (state !== "networkidle" ||
          (network.requests.size === 0 && Date.now() - network.changedAt >= 500))
      )
        return
    }
    if (Date.now() >= deadline)
      throw new Error(
        `Timed out waiting for ${options.afterSequence === undefined ? "page" : "navigation"} ${state}${options.url ? ` at ${options.url}` : ""}`
      )
    await delay(Math.min(50, Math.max(1, deadline - Date.now())))
  }
}
