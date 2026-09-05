import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import type { BrowserRuntime, PageHandle } from "./browser-cdp-engine.js"
import {
  browserNavigationBaseline,
  observeBrowserLoadEvent,
  waitForBrowserState
} from "./browser-load-state.js"

// The load-state policy owns timing. Exercise it without sockets or Chromium;
// browser-improvements.test.ts separately covers real CDP event delivery.
const fixture = () => {
  let readyState = "complete"
  const send = vi.fn(async (method: string) => {
    if (method === "Page.getFrameTree") return { frameTree: { frame: { id: "frame" } } }
    if (method === "Runtime.evaluate") return { result: { value: readyState } }
    throw new Error(`Unexpected CDP request: ${method}`)
  })
  const runtime = {
    connection: { send },
    sessions: new Map([["tab", "session"]]),
    snapshots: new Map(),
    eventSequence: 0,
    eventLog: []
  } as unknown as BrowserRuntime
  const page: PageHandle = {
    target: { targetId: "tab", type: "page", title: "Fixture", url: "about:blank" },
    sessionId: "session"
  }
  const event = (
    method: string,
    params: Record<string, unknown>,
    sessionId: string | undefined = page.sessionId
  ) => {
    observeBrowserLoadEvent(runtime, method, params, sessionId)
    runtime.eventLog.push({ method, params, sessionId, sequence: ++runtime.eventSequence })
  }
  return { runtime, page, event, setReady: (state: string) => (readyState = state) }
}

beforeEach(() => vi.useFakeTimers())
afterEach(() => {
  vi.clearAllTimers()
  vi.useRealTimers()
})

describe("Browser load state", () => {
  it("requires navigation after the baseline, on the requested frame and session", async () => {
    const { runtime, page, event } = fixture()
    event("Page.frameNavigated", { frame: { id: "frame" } })
    const baseline = await browserNavigationBaseline(runtime, page)
    event("Page.frameNavigated", { frame: { id: "other-frame" } })
    event("Page.navigatedWithinDocument", { frameId: "frame" }, "other-session")
    const failed = vi.fn()
    const operation = waitForBrowserState(runtime, page, {
      ...baseline,
      state: "commit",
      timeoutMs: 1000
    }).catch(failed)
    await vi.advanceTimersByTimeAsync(999)
    expect(failed).not.toHaveBeenCalled()
    await vi.advanceTimersByTimeAsync(1)
    await operation
    expect(failed).toHaveBeenCalledExactlyOnceWith(
      new Error("Timed out waiting for navigation commit")
    )
  })

  it.each(["Page.frameNavigated", "Page.navigatedWithinDocument"])(
    "accepts a buffered %s event after arming",
    async (method) => {
      const { runtime, page, event } = fixture()
      const baseline = await browserNavigationBaseline(runtime, page)
      runtime.snapshots.set("owner:tab", { id: "old", targets: new Map() })
      event(method, { frame: { id: "frame" }, frameId: "frame" })
      await waitForBrowserState(runtime, page, { ...baseline, state: "commit" })
      expect(runtime.snapshots.has("owner:tab")).toBe(false)
      expect(vi.getTimerCount()).toBe(0)
    }
  )

  it.each(["Network.loadingFinished", "Network.loadingFailed"])(
    "waits for outstanding requests and 500ms of quiet after %s",
    async (method) => {
      const { runtime, page, event } = fixture()
      event("Network.requestWillBeSent", { requestId: "request", type: "Fetch" })
      const completed = vi.fn()
      const operation = waitForBrowserState(runtime, page, { state: "networkidle" }).then(completed)
      await vi.advanceTimersByTimeAsync(1000)
      expect(completed).not.toHaveBeenCalled()
      event(method, { requestId: "request" })
      await vi.advanceTimersByTimeAsync(499)
      expect(completed).not.toHaveBeenCalled()
      await vi.advanceTimersByTimeAsync(1)
      await operation
      expect(completed).toHaveBeenCalledOnce()
      expect(vi.getTimerCount()).toBe(0)
    }
  )

  it("restarts the quiet interval when another request arrives", async () => {
    const { runtime, page, event } = fixture()
    const completed = vi.fn()
    const operation = waitForBrowserState(runtime, page, { state: "networkidle" }).then(completed)
    await vi.advanceTimersByTimeAsync(450)
    event("Network.requestWillBeSent", { requestId: "late", type: "Fetch" })
    await vi.advanceTimersByTimeAsync(50)
    expect(completed).not.toHaveBeenCalled()
    event("Network.loadingFinished", { requestId: "late" })
    await vi.advanceTimersByTimeAsync(499)
    expect(completed).not.toHaveBeenCalled()
    await vi.advanceTimersByTimeAsync(1)
    await operation
    expect(completed).toHaveBeenCalledOnce()
  })

  it("ignores persistent connections and another session's requests", async () => {
    const { runtime, page, event } = fixture()
    event("Network.requestWillBeSent", { requestId: "socket", type: "WebSocket" })
    event("Network.requestWillBeSent", { requestId: "events", type: "EventSource" })
    event("Network.requestWillBeSent", { requestId: "other", type: "Fetch" }, "other-session")
    const operation = waitForBrowserState(runtime, page, { state: "networkidle" })
    await vi.advanceTimersByTimeAsync(500)
    await operation
  })

  it("uses monotonic elapsed time when the wall clock changes", async () => {
    const { runtime, page, event } = fixture()
    event("Network.loadingFinished", { requestId: "request" })
    const completed = vi.fn()
    const operation = waitForBrowserState(runtime, page, { state: "networkidle" }).then(completed)
    vi.setSystemTime(new Date("2000-01-01T00:00:00Z"))
    await vi.advanceTimersByTimeAsync(499)
    expect(completed).not.toHaveBeenCalled()
    await vi.advanceTimersByTimeAsync(1)
    await operation
    expect(completed).toHaveBeenCalledOnce()
  })

  it("distinguishes DOM readiness from the load event", async () => {
    const { runtime, page, setReady } = fixture()
    setReady("interactive")
    await waitForBrowserState(runtime, page, { state: "domcontentloaded" })
    const completed = vi.fn()
    const operation = waitForBrowserState(runtime, page, { state: "load" }).then(completed)
    await vi.advanceTimersByTimeAsync(50)
    expect(completed).not.toHaveBeenCalled()
    setReady("complete")
    await vi.advanceTimersByTimeAsync(50)
    await operation
    expect(completed).toHaveBeenCalledOnce()
  })
})
