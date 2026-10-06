import { describe, expect, it } from "vitest"

import type { BrowserRuntime } from "./browser-cdp-engine.js"
import {
  makeBrowserPreviews,
  type BrowserPreviewStatus,
  type BrowserPreviewViewer
} from "./browser-preview.js"

/// A fake CDP connection for one browser: the commands the preview sends,
/// the screencast events it listens for, and a target list with titles.
const browser = (
  options: {
    failStart?: boolean
    failTargets?: boolean
    failPage?: boolean
    failAttach?: boolean
  } = {}
) => {
  const sent: Array<{
    method: string
    params: Readonly<Record<string, unknown>>
    session?: string
  }> = []
  const handlers = new Map<string, (params: Readonly<Record<string, unknown>>) => void>()
  const titles = new Map<string, { title?: string; url?: string }>([
    ["tab-1", { title: "Example", url: "https://example.com/" }],
    ["tab-2", { url: "https://other.test/" }],
    ["tab-blank", {}]
  ])
  const connection = {
    closed: false,
    send: async (
      method: string,
      params: Readonly<Record<string, unknown>> = {},
      session?: string
    ) => {
      sent.push({ method, params, ...(session === undefined ? {} : { session }) })
      if (method === "Page.startScreencast" && options.failStart) throw new Error("Target closed")
      if (
        options.failPage &&
        (method === "Page.stopScreencast" || method === "Page.screencastFrameAck")
      )
        throw new Error("Target closed")
      if (method === "Target.getTargets") {
        if (options.failTargets) throw new Error("disconnected")
        return {
          targetInfos: [...titles].map(([targetId, info]) => ({ targetId, ...info }))
        }
      }
      return {}
    },
    sendOnce: async (method: string, params: Readonly<Record<string, unknown>> = {}) => {
      sent.push({ method, params })
      if (method === "Target.attachToTarget" && options.failAttach) throw new Error("No target")
      return method === "Target.attachToTarget"
        ? { sessionId: `cdp:${String(params.targetId)}` }
        : {}
    },
    on: (
      method: string,
      handler: (params: Readonly<Record<string, unknown>>) => void,
      session?: string
    ) => {
      handlers.set(`${session}:${method}`, handler)
      return () => handlers.delete(`${session}:${method}`)
    }
  }
  const runtime = { connection, sessions: new Map<string, string>() } as unknown as BrowserRuntime
  const frame = (session: string, data: unknown, frameId = 1) =>
    handlers.get(`${session}:Page.screencastFrame`)?.({ data, sessionId: frameId })
  const methods = () =>
    sent.map(({ method, session }) => `${method}${session ? `@${session}` : ""}`)
  return { runtime, connection, sent, methods, frame, handlers }
}

const viewer = () => {
  const statuses: BrowserPreviewStatus[] = []
  const frames: string[] = []
  const value: BrowserPreviewViewer = {
    status: (status) => statuses.push(status),
    frame: (data) => frames.push(data)
  }
  return { value, statuses, frames }
}

/// Manual timers: the idle timeout fires when the test says so.
const timers = () => {
  const pending = new Set<() => void>()
  return {
    options: {
      setTimer: (callback: () => void) => {
        pending.add(callback)
        return callback
      },
      clearTimer: (timer: unknown) => {
        pending.delete(timer as () => void)
      }
    },
    fire: () => {
      for (const callback of pending) {
        pending.delete(callback)
        callback()
      }
    },
    count: () => pending.size
  }
}

describe("Browser live preview", () => {
  it("casts the agent's tab only while someone watches, at the largest watched size", async () => {
    const chrome = browser()
    const previews = makeBrowserPreviews(timers().options)
    const watcher = viewer()
    const subscription = previews.subscribe("chat", watcher.value)
    expect(watcher.statuses).toEqual([{ state: "inactive", title: "", url: "" }])

    await previews.activity("chat", chrome.runtime, "tab-1")
    // Active, but nobody is watching frames yet: no screencast.
    expect(chrome.methods()).not.toContain("Page.startScreencast@cdp:tab-1")
    subscription.watch(4000)
    await previews.activity("chat", chrome.runtime, "tab-1")
    expect(
      chrome.sent.find((sent) => sent.method === "Page.startScreencast")?.params
    ).toMatchObject({
      format: "jpeg",
      maxWidth: 1920,
      maxHeight: 1920
    })
    expect(watcher.statuses).toContainEqual({
      state: "active",
      title: "Example",
      url: "https://example.com/"
    })

    chrome.frame("cdp:tab-1", "jpeg-1", 7)
    chrome.frame("cdp:tab-1", 42)
    expect(watcher.frames).toEqual(["jpeg-1"])
    expect(chrome.sent).toContainEqual({
      method: "Page.screencastFrameAck",
      params: { sessionId: 7 },
      session: "cdp:tab-1"
    })

    subscription.unwatch()
    await previews.activity("chat", chrome.runtime, "tab-1")
    expect(chrome.methods()).toContain("Page.stopScreencast@cdp:tab-1")
    chrome.frame("cdp:tab-1", "jpeg-2")
    expect(watcher.frames).toEqual(["jpeg-1"])
    subscription.close()
    subscription.watch(800)
    subscription.unwatch()
    subscription.close()
  })

  it("follows the agent to another tab and resizes for a bigger viewer", async () => {
    const chrome = browser()
    const previews = makeBrowserPreviews(timers().options)
    const first = viewer()
    previews.subscribe("chat", first.value).watch(100)
    await previews.activity("chat", chrome.runtime, "tab-1")
    previews.subscribe("chat", viewer().value).watch(1000)
    await previews.activity("chat", chrome.runtime, "tab-1")
    await previews.activity("chat", chrome.runtime, "tab-2")

    expect(
      chrome.sent
        .filter((sent) => sent.method.endsWith("Screencast"))
        .map(
          ({ method, session, params }) => `${method}@${session}:${String(params.maxWidth ?? "")}`
        )
    ).toEqual([
      "Page.startScreencast@cdp:tab-1:320",
      "Page.stopScreencast@cdp:tab-1:",
      "Page.startScreencast@cdp:tab-1:1000",
      "Page.stopScreencast@cdp:tab-1:",
      "Page.startScreencast@cdp:tab-2:1000"
    ])
    // A tab without a title is named by its address.
    expect(first.statuses.at(-1)).toMatchObject({ title: "Example" })
  })

  it("idles after a pause, stops at turn end, and forgets a closed session", async () => {
    const clock = timers()
    const chrome = browser()
    const previews = makeBrowserPreviews(clock.options)
    const watcher = viewer()
    const subscription = previews.subscribe("chat", watcher.value)
    subscription.watch(800)
    await previews.activity("chat", chrome.runtime, "tab-1")
    await previews.activity("chat", chrome.runtime, "tab-1")
    expect(clock.count()).toBe(1)

    clock.fire()
    await previews.finish("other")
    await previews.activity("chat", chrome.runtime, "tab-1")
    const states = watcher.statuses.map((status) => status.state)
    // State transitions; the page title arriving is an update of its own.
    expect(states.filter((state, index) => state !== states[index - 1])).toEqual([
      "inactive",
      "active",
      "idle",
      "active"
    ])
    await previews.finish("chat")
    expect(watcher.statuses.at(-1)?.state).toBe("stopped")
    expect(clock.count()).toBe(0)
    await previews.finish("chat")
    expect(watcher.statuses.filter((status) => status.state === "stopped")).toHaveLength(1)

    await previews.activity("chat", chrome.runtime, "tab-1")
    await previews.close("chat")
    await previews.close("missing")
    expect(watcher.statuses.at(-1)?.state).toBe("stopped")
    subscription.close()
    await new Promise((resolve) => setImmediate(resolve))
    // A new subscriber starts over: the closed session was forgotten.
    const fresh = viewer()
    previews.subscribe("chat", fresh.value)
    expect(fresh.statuses).toEqual([{ state: "inactive", title: "", url: "" }])
  })

  it("forgets a session closed while nobody watches, and one that was never used", async () => {
    const chrome = browser()
    const previews = makeBrowserPreviews(timers().options)
    await previews.activity("chat", chrome.runtime, "tab-1")
    await previews.close("chat")
    const later = viewer()
    previews.subscribe("chat", later.value)
    expect(later.statuses).toEqual([{ state: "inactive", title: "", url: "" }])

    const unused = previews.subscribe("unused", viewer().value)
    await previews.close("unused")
    unused.close()
  })

  it("survives a tab that can't be cast, a closed browser, and a failed title lookup", async () => {
    const failing = browser({ failStart: true, failTargets: true })
    const previews = makeBrowserPreviews(timers().options)
    const watcher = viewer()
    previews.subscribe("chat", watcher.value).watch(800)
    await previews.activity("chat", failing.runtime, "tab-1")
    expect(failing.methods()).toContain("Page.stopScreencast@cdp:tab-1")
    expect(watcher.statuses.at(-1)).toMatchObject({ state: "active", title: "" })

    const closed = browser()
    ;(closed.connection as { closed: boolean }).closed = true
    await previews.activity("chat", closed.runtime, "tab-1")
    expect(closed.methods()).not.toContain("Page.startScreencast@cdp:tab-1")
  })

  it("restarts the screencast when the browser behind it closes", async () => {
    const chrome = browser()
    const previews = makeBrowserPreviews(timers().options)
    previews.subscribe("chat", viewer().value).watch(800)
    await previews.activity("chat", chrome.runtime, "tab-1")
    ;(chrome.connection as { closed: boolean }).closed = true
    const replacement = browser()
    replacement.runtime.sessions.set("tab-1", "existing")
    await previews.activity("chat", replacement.runtime, "tab-1")
    expect(replacement.methods()).toContain("Page.startScreencast@existing")
  })

  it("keeps going when acknowledging a frame or stopping the cast fails", async () => {
    const chrome = browser({ failPage: true })
    const previews = makeBrowserPreviews(timers().options)
    const watcher = viewer()
    const subscription = previews.subscribe("chat", watcher.value)
    subscription.watch(800)
    await previews.activity("chat", chrome.runtime, "tab-1")
    chrome.frame("cdp:tab-1", "jpeg-1")
    await new Promise((resolve) => setImmediate(resolve))
    expect(watcher.frames).toEqual(["jpeg-1"])
    subscription.unwatch()
    await previews.finish("chat")
    expect(chrome.methods()).toContain("Page.stopScreencast@cdp:tab-1")
  })

  it("handles odd sizes, idle viewers, unattachable tabs, and tabs missing from the list", async () => {
    const chrome = browser()
    const previews = makeBrowserPreviews(timers().options)
    const watching = viewer()
    const idle = viewer()
    previews.subscribe("chat", watching.value).watch(Number.NaN)
    previews.subscribe("chat", idle.value)
    await previews.activity("chat", chrome.runtime, "tab-blank")
    await new Promise((resolve) => setImmediate(resolve))
    expect(
      chrome.sent.find((sent) => sent.method === "Page.startScreencast")?.params
    ).toMatchObject({
      maxWidth: 1280
    })
    chrome.frame("cdp:tab-blank", "jpeg-1")
    expect(watching.frames).toEqual(["jpeg-1"])
    expect(idle.frames).toEqual([])
    // A tab with neither title nor address is shown untitled.
    expect(watching.statuses.at(-1)).toMatchObject({ state: "active", title: "", url: "" })

    const unattached = browser({ failAttach: true })
    const unknown = makeBrowserPreviews(timers().options)
    const missing = viewer()
    unknown.subscribe("chat", missing.value).watch(800)
    await unknown.activity("chat", unattached.runtime, "tab-gone")
    await new Promise((resolve) => setImmediate(resolve))
    expect(unattached.methods()).not.toContain("Page.startScreencast")
    expect(missing.statuses.at(-1)).toMatchObject({ state: "active", title: "" })
  })

  it("uses real timers by default", async () => {
    const chrome = browser()
    const previews = makeBrowserPreviews()
    await previews.activity("chat", chrome.runtime, "tab-1")
    await previews.finish("chat")
  })
})
