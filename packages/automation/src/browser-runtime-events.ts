import { randomUUID } from "node:crypto"
import { join } from "node:path"

import type { BrowserRuntime } from "./browser-cdp-engine.js"
import { observeBrowserLoadEvent } from "./browser-load-state.js"
import { handleTargetLifecycleEvent, installSessionRecovery } from "./browser-session-recovery.js"

type CdpParams = Readonly<Record<string, unknown>>
type BrowserDownload = BrowserRuntime["downloads"] extends Map<string, infer D> ? D : never

function downloadProgressState(params: CdpParams, existing: BrowserDownload) {
  if (typeof params.state === "string") return { state: params.state }
  if (existing.state === undefined) return {}
  return { state: existing.state }
}

type DownloadParams = CdpParams & { readonly guid: string }

function hasDownloadGuid(params: CdpParams): params is DownloadParams {
  return typeof params.guid === "string"
}

function downloadProgressPath(
  params: DownloadParams,
  existing: BrowserDownload,
  downloadsDir: string
) {
  if (typeof params.filePath === "string") return { path: params.filePath }
  if (params.state === "completed" && existing.path === undefined)
    return { path: join(downloadsDir, params.guid) }
  return {}
}

export function observeBrowserRuntime(
  active: BrowserRuntime,
  downloadsDir: string,
  extension: boolean
): void {
  installSessionRecovery(active, extension)
  active.eventDisposers.push(
    active.connection.on("*", (params, event) => {
      observeBrowserLoadEvent(active, event.method, params, event.sessionId)
      const sequence = ++active.eventSequence
      active.eventLog.push({
        method: event.method,
        params,
        sequence,
        ...(event.sessionId === undefined ? {} : { sessionId: event.sessionId })
      })
      if (active.eventLog.length > 5_000) active.eventLog.splice(0, active.eventLog.length - 5_000)
      handleTargetLifecycleEvent(active, event.method, params)
      if (event.sessionId !== undefined) {
        if (
          event.method === "Runtime.consoleAPICalled" ||
          event.method === "Runtime.exceptionThrown" ||
          event.method === "Log.entryAdded"
        ) {
          const entries = active.logs.get(event.sessionId) ?? []
          entries.push({ method: event.method, ...params, sequence })
          if (entries.length > 1_000) entries.splice(0, entries.length - 1_000)
          active.logs.set(event.sessionId, entries)
        } else if (event.method === "Page.javascriptDialogOpening") {
          active.dialogs.set(event.sessionId, { ...params })
        } else if (event.method === "Page.javascriptDialogClosed") {
          active.dialogs.delete(event.sessionId)
        }
      }
      if (
        event.method === "Browser.downloadWillBegin" ||
        event.method === "Page.downloadWillBegin"
      ) {
        const guid = typeof params.guid === "string" ? params.guid : randomUUID()
        active.downloads.set(guid, {
          guid,
          url: typeof params.url === "string" ? params.url : "",
          suggestedFilename:
            typeof params.suggestedFilename === "string" ? params.suggestedFilename : "download",
          ...(typeof params.filePath === "string" ? { path: params.filePath } : {})
        })
      } else if (
        (event.method === "Browser.downloadProgress" || event.method === "Page.downloadProgress") &&
        hasDownloadGuid(params)
      ) {
        const existing = active.downloads.get(params.guid)
        if (existing !== undefined) {
          active.downloads.set(params.guid, {
            ...existing,
            ...downloadProgressState(params, existing),
            ...downloadProgressPath(params, existing, downloadsDir)
          })
        }
      }
    })
  )
}
