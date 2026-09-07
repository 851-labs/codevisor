import { expect, it, vi } from "vitest"
import type { BrowserRuntime } from "./browser-cdp-engine.js"
import type { CdpConnection } from "./browser-cdp.js"
import { observeBrowserRuntime } from "./browser-runtime-events.js"

function fixture() {
  const stopEvents = vi.fn()
  const stopRecovery = vi.fn()
  let listener: Parameters<CdpConnection["on"]>[1]
  const runtime: BrowserRuntime = {
    connection: {
      on: (_method: string, handler: typeof listener) => {
        listener = handler
        return stopEvents
      },
      setSessionRecoveryHandler: () => stopRecovery
    } as unknown as CdpConnection,
    owned: false,
    processHandle: undefined,
    sessions: new Map(),
    staleSessions: new Map(),
    snapshots: new Map(),
    eventLog: [],
    logs: new Map(),
    dialogs: new Map(),
    fileChoosers: new Map(),
    downloads: new Map(),
    eventDisposers: [],
    eventSequence: 0,
    tabOrder: [],
    queue: Promise.resolve()
  }
  observeBrowserRuntime(runtime, "/downloads", false)
  const emit = (method: string, params: Record<string, unknown> = {}, sessionId?: string) =>
    listener(params, { method, params, ...(sessionId === undefined ? {} : { sessionId }) })
  return { runtime, emit, stopEvents, stopRecovery }
}

it("retains bounded event and console history with monotonic sequence numbers", () => {
  const { runtime, emit, stopEvents, stopRecovery } = fixture()
  for (let index = 0; index < 5001; index++) emit("Page.testEvent", { index })
  expect(runtime.eventLog).toHaveLength(5000)
  expect(runtime.eventLog[0]).toEqual({
    method: "Page.testEvent",
    params: { index: 1 },
    sequence: 2
  })
  for (let index = 0; index < 1001; index++) emit("Runtime.consoleAPICalled", { index }, "page")
  expect(runtime.logs.get("page")).toHaveLength(1000)
  expect(runtime.logs.get("page")![0]).toMatchObject({ index: 1, sequence: 5003 })
  emit("Runtime.exceptionThrown", { message: "failed" }, "other")
  emit("Log.entryAdded", { message: "warning" }, "other")
  expect(runtime.logs.get("other")!.map((entry) => entry.method)).toEqual([
    "Runtime.exceptionThrown",
    "Log.entryAdded"
  ])
  expect(runtime.eventLog.at(-1)).toMatchObject({ sessionId: "other", sequence: 6004 })
  for (const dispose of runtime.eventDisposers) dispose()
  expect(stopEvents).toHaveBeenCalledOnce()
  expect(stopRecovery).toHaveBeenCalledOnce()
})

it("tracks dialogs per page and forgets destroyed targets", () => {
  const { runtime, emit } = fixture()
  emit("Page.javascriptDialogOpening", { type: "confirm" }, "page")
  expect(runtime.dialogs.get("page")).toEqual({ type: "confirm" })
  emit("Page.javascriptDialogClosed", {}, "page")
  expect(runtime.dialogs.has("page")).toBe(false)
  runtime.tabOrder = ["first", "second"]
  emit("Target.targetDestroyed", { targetId: "first" })
  expect(runtime.tabOrder).toEqual(["second"])
})

it("tracks download progress, preserves supplied paths and resolves completed downloads", () => {
  const { runtime, emit } = fixture()
  emit("Browser.downloadWillBegin", {
    guid: "one",
    url: "https://example.com/file",
    suggestedFilename: "file.txt"
  })
  emit("Browser.downloadProgress", { guid: "one" })
  expect(runtime.downloads.get("one")).toEqual({
    guid: "one",
    url: "https://example.com/file",
    suggestedFilename: "file.txt"
  })
  emit("Browser.downloadProgress", { guid: "one", state: "inProgress" })
  emit("Browser.downloadProgress", { guid: "one" })
  expect(runtime.downloads.get("one")!.state).toBe("inProgress")
  emit("Browser.downloadProgress", { guid: "one", state: "completed" })
  expect(runtime.downloads.get("one")).toMatchObject({ state: "completed", path: "/downloads/one" })
  emit("Page.downloadWillBegin", { guid: "two", filePath: "/custom/file" })
  emit("Page.downloadProgress", { guid: "two", state: "completed" })
  expect(runtime.downloads.get("two")).toMatchObject({
    path: "/custom/file",
    suggestedFilename: "download",
    url: ""
  })
  emit("Page.downloadProgress", { guid: "two", filePath: "/custom/moved" })
  expect(runtime.downloads.get("two")!.path).toBe("/custom/moved")
  emit("Page.downloadProgress", { guid: "unknown", state: "completed" })
  emit("Page.downloadProgress", { state: "completed" })
  expect(runtime.downloads.size).toBe(2)
})

it("assigns an identity to downloads missing an upstream guid", () => {
  const { runtime, emit } = fixture()
  emit("Page.downloadWillBegin")
  const [download] = runtime.downloads.values()
  expect(download).toMatchObject({
    guid: expect.any(String),
    url: "",
    suggestedFilename: "download"
  })
  emit("Page.downloadProgress", { guid: download!.guid, state: "canceled" })
  expect(runtime.downloads.get(download!.guid)!.state).toBe("canceled")
})
