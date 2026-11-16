import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

import type { PageHandle } from "./browser-cdp-engine.js"
import {
  browserNavigationBaseline,
  observeBrowserLoadEvent,
  waitForBrowserState
} from "./browser-load-state.js"
import { fakeBrowserRuntime, fakeCdpConnection } from "./browser-runtime-test-support.js"

const fixture = () => {
  let readyState = "complete"
  const send = vi.fn(async (method: string) => {
    if (method === "Page.getFrameTree") return { frameTree: { frame: { id: "frame" } } }
    if (method === "Runtime.evaluate") return { result: { value: readyState } }
    throw new Error(`Unexpected CDP request: ${method}`)
  })
  const runtime = fakeBrowserRuntime({
    connection: fakeCdpConnection({ send }).connection,
    sessions: new Map([["tab", "session"]])
  })
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
      runtime.snapshots.set("owner:tab", {
        id: "old",
        targets: new Map(),
        frames: new Map(),
        lines: [],
        clipped: false
      })
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
    event("Network.requestWillBeSent", { requestId: "beacon", type: "Ping" })
    event("Network.requestWillBeSent", { requestId: "stream", type: "Fetch" })
    event("Network.responseReceived", {
      requestId: "stream",
      response: { mimeType: "text/event-stream" }
    })
    event("Network.requestWillBeSent", { requestId: "other", type: "Fetch" }, "other-session")
    const operation = waitForBrowserState(runtime, page, { state: "networkidle" })
    await vi.advanceTimersByTimeAsync(500)
    await operation
  })

  it("stops waiting for a request that has stayed open for five seconds", async () => {
    const { runtime, page, event } = fixture()
    event("Network.requestWillBeSent", { requestId: "long-poll", type: "Fetch" })
    const completed = vi.fn()
    const operation = waitForBrowserState(runtime, page, { state: "networkidle" }).then(completed)
    await vi.advanceTimersByTimeAsync(4999)
    expect(completed).not.toHaveBeenCalled()
    await vi.advanceTimersByTimeAsync(1)
    await operation
    expect(completed).toHaveBeenCalledOnce()
  })

  it("stays idle when a request it stopped waiting for finally ends", async () => {
    const { runtime, page, event } = fixture()
    event("Network.requestWillBeSent", { requestId: "long-poll", type: "Fetch" })
    await vi.advanceTimersByTimeAsync(5000)
    event("Network.loadingFinished", { requestId: "long-poll" })
    await waitForBrowserState(runtime, page, { state: "networkidle" })
    expect(vi.getTimerCount()).toBe(0)
  })

  it("stops counting a frame's page load when the frame moves to another process", async () => {
    const { runtime, page, event } = fixture()
    event("Network.requestWillBeSent", { requestId: "ad", type: "Document", frameId: "ad-frame" })
    event("Network.requestWillBeSent", { requestId: "own", type: "Fetch", frameId: "frame" })
    await vi.advanceTimersByTimeAsync(500)
    event("Page.frameDetached", { frameId: "ad-frame", reason: "swap" })
    const completed = vi.fn()
    const operation = waitForBrowserState(runtime, page, { state: "networkidle" }).then(completed)
    await vi.advanceTimersByTimeAsync(50)
    expect(completed).not.toHaveBeenCalled()
    event("Network.loadingFinished", { requestId: "own" })
    await vi.advanceTimersByTimeAsync(500)
    await operation
    expect(completed).toHaveBeenCalledOnce()
  })

  it("forgets the previous document's unfinished requests after a navigation", async () => {
    const { runtime, page, event } = fixture()
    event("Network.requestWillBeSent", { requestId: "left-behind", type: "Fetch", loaderId: "old" })
    event("Network.requestWillBeSent", { requestId: "new", type: "Document", loaderId: "new" })
    event("Page.frameNavigated", { frame: { id: "frame", loaderId: "new" } })
    event("Network.loadingFinished", { requestId: "new" })
    const operation = waitForBrowserState(runtime, page, { state: "networkidle" })
    await vi.advanceTimersByTimeAsync(500)
    await operation
  })

  it("names the latest request when the page never goes quiet", async () => {
    const { runtime, page, event } = fixture()
    const failed = vi.fn()
    const operation = waitForBrowserState(runtime, page, {
      state: "networkidle",
      timeoutMs: 1000
    }).catch(failed)
    for (let poll = 0; poll < 4; poll++) {
      event("Network.requestWillBeSent", {
        requestId: `poll-${poll}`,
        type: "Fetch",
        request: { url: "https://example.test/poll" }
      })
      event("Network.loadingFinished", { requestId: `poll-${poll}` })
      await vi.advanceTimersByTimeAsync(250)
    }
    await operation
    expect(failed).toHaveBeenCalledExactlyOnceWith(
      new Error(
        "Timed out waiting for page networkidle: the page is still making requests (latest https://example.test/poll). Wait for the content you need with a locator instead"
      )
    )
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
