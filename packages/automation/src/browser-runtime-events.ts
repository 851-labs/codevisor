import { randomUUID } from "node:crypto"
import { join } from "node:path"
import type { BrowserRuntime } from "./browser-cdp-engine.js"
import { observeBrowserLoadEvent } from "./browser-load-state.js"
import { handleTargetLifecycleEvent, installSessionRecovery } from "./browser-session-recovery.js"

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
          url: String(params.url ?? ""),
          suggestedFilename: String(params.suggestedFilename ?? "download"),
          ...(typeof params.filePath === "string" ? { path: params.filePath } : {})
        })
      } else if (
        (event.method === "Browser.downloadProgress" || event.method === "Page.downloadProgress") &&
        typeof params.guid === "string"
      ) {
        const existing = active.downloads.get(params.guid)
        if (existing !== undefined) {
          active.downloads.set(params.guid, {
            ...existing,
            ...(typeof params.state === "string"
              ? { state: params.state }
              : existing.state === undefined
                ? {}
                : { state: existing.state }),
            ...(typeof params.filePath === "string"
              ? { path: params.filePath }
              : params.state === "completed" && existing.path === undefined
                ? { path: join(downloadsDir, params.guid) }
                : {})
          })
        }
      }
    })
  )
}
