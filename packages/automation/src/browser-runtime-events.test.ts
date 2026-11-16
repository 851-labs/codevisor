import { mkdtempSync, readFileSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { expect, it, onTestFinished, vi } from "vitest"

import type { CdpConnection } from "./browser-cdp.js"
import { readBrowserLogs } from "./browser-logs.js"
import { observeBrowserRuntime } from "./browser-runtime-events.js"
import { fakeBrowserRuntime, fakeCdpConnection } from "./browser-runtime-test-support.js"

const chunk = (text: string) => Buffer.from(text).toString("base64")

function fixture(options: { native?: boolean; downloadsDir?: string } = {}) {
  const stopEvents = vi.fn()
  const stopRecovery = vi.fn()
  let listener: Parameters<CdpConnection["on"]>[1]
  const runtime = fakeBrowserRuntime({
    ...(options.native === true ? { native: true } : {}),
    connection: fakeCdpConnection({
      on: (_method, handler) => {
        listener = handler
        return stopEvents
      },
      setSessionRecoveryHandler: () => stopRecovery
    }).connection
  })
  observeBrowserRuntime(runtime, options.downloadsDir ?? "/downloads", false)
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

it("records a permission request the pane refused as a warning in that tab's logs", () => {
  const { runtime, emit } = fixture({ native: true })
  emit(
    "Codevisor.permissionRequested",
    { origin: "https://maps.test/", permissions: ["location", "notifications"] },
    "page"
  )
  expect(readBrowserLogs(runtime.logs, ["page"], {})).toEqual([
    expect.objectContaining({
      level: "warn",
      url: "https://maps.test/",
      message: expect.stringContaining(
        "The page asked for location, notifications and was refused: the built-in pane grants no permissions."
      )
    })
  ])
  expect(runtime.logs.has("other")).toBe(false)
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

it("stores the file a built-in pane sends for a download, and ignores it from other browsers", () => {
  const downloadsDir = mkdtempSync(join(tmpdir(), "pane-downloads-"))
  onTestFinished(() => rmSync(downloadsDir, { recursive: true, force: true }))
  const pane = fixture({ native: true, downloadsDir })
  pane.emit("Browser.downloadWillBegin", { guid: "pane-1", url: "", suggestedFilename: "a.txt" })
  pane.emit("Codevisor.downloadData", { guid: "pane-1", data: chunk("hello ") })
  pane.emit("Codevisor.downloadData", { guid: "pane-1", data: chunk("download") })
  pane.emit("Codevisor.downloadData", { guid: "../escape", data: chunk("no") })
  pane.emit("Browser.downloadProgress", { guid: "pane-1", state: "completed" })
  expect(pane.runtime.downloads.get("pane-1")).toMatchObject({
    state: "completed",
    path: join(downloadsDir, "pane-1")
  })
  expect(readFileSync(join(downloadsDir, "pane-1"), "utf8")).toBe("hello download")

  const managed = fixture({ downloadsDir })
  managed.emit("Codevisor.downloadData", { guid: "managed-1", data: chunk("no") })
  expect(() => readFileSync(join(downloadsDir, "managed-1"))).toThrow()
  expect(() => readFileSync(join(downloadsDir, "..", "escape"))).toThrow()
})
