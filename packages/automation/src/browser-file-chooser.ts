import { randomUUID } from "node:crypto"

import type { CallToolResult } from "@modelcontextprotocol/server"

import { jsonResult, type BrowserRuntime, type PageHandle } from "./browser-cdp-engine.js"
import { tabSessionIds } from "./browser-frame-sessions.js"

interface OpenedFileChooser {
  readonly sessionId: string
  readonly tabSessionId: string
  readonly backendNodeId: number
  readonly multiple: boolean
}

export const waitForFileChooser = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  timeoutMs: number
): Promise<CallToolResult> => {
  const sessionIds = tabSessionIds(runtime, page.sessionId)
  const opened = openedFileChooser(runtime, sessionIds, timeoutMs)
  await Promise.all(sessionIds.map((sessionId) => interceptFileChoosers(runtime, sessionId, true)))
  const { multiple, ...chooser } = await opened
  const chooserId = randomUUID()
  runtime.fileChoosers.set(chooserId, chooser)
  return jsonResult({ event: "filechooser", chooserId, multiple })
}

export const setFileChooserFiles = async (
  runtime: BrowserRuntime,
  chooserId: string,
  paths: ReadonlyArray<string>
): Promise<CallToolResult> => {
  const chooser = runtime.fileChoosers.get(chooserId)
  if (chooser === undefined) throw new Error("Unknown or expired file chooser")
  await runtime.connection.send(
    "DOM.setFileInputFiles",
    { files: paths, backendNodeId: chooser.backendNodeId },
    chooser.sessionId
  )
  runtime.fileChoosers.delete(chooserId)
  const sessionIds = tabSessionIds(runtime, chooser.tabSessionId ?? chooser.sessionId)
  await Promise.all(sessionIds.map((sessionId) => interceptFileChoosers(runtime, sessionId, false)))
  return jsonResult({ fileCount: paths.length })
}

const interceptFileChoosers = (
  runtime: BrowserRuntime,
  sessionId: string,
  enabled: boolean
): Promise<unknown> =>
  runtime.connection
    .send("Page.setInterceptFileChooserDialog", { enabled }, sessionId)
    .catch(() => undefined)

const openedFileChooser = (
  runtime: BrowserRuntime,
  sessionIds: ReadonlyArray<string>,
  timeoutMs: number
): Promise<OpenedFileChooser> =>
  new Promise((resolve, reject) => {
    const tabSessionId = sessionIds[0]!
    const stop = runtime.connection.on("Page.fileChooserOpened", (params, event) => {
      const sessionId = event.sessionId
      if (sessionId === undefined || !sessionIds.includes(sessionId)) return
      finish()
      const backendNodeId = Number(params.backendNodeId)
      if (!Number.isInteger(backendNodeId)) {
        reject(new Error("The file chooser did not identify its file input"))
        return
      }
      resolve({
        sessionId,
        tabSessionId,
        backendNodeId,
        multiple: params.mode === "selectMultiple"
      })
    })
    const timer = setTimeout(() => {
      finish()
      reject(new Error("Timed out waiting for Page.fileChooserOpened"))
    }, timeoutMs)
    timer.unref?.()
    const finish = () => {
      clearTimeout(timer)
      stop()
    }
  })
