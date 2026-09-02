import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"
import { randomUUID } from "node:crypto"
import { join } from "node:path"
import { delay, evaluatedValue } from "./browser-cdp.js"
import {
  actionResult,
  booleanArgument,
  evaluate,
  evaluateReadOnly,
  jsonResult,
  numberArgument,
  pageInformation,
  stringArgument,
  verifiedActionResult,
  waitForCdpEvent,
  waitForReady
} from "./browser-cdp-engine.js"
import {
  dispatchClick,
  fillResolvedElement,
  mouseModifierMask,
  pressKey,
  selectOptionsElement,
  setCheckedElement,
  triggerMediaDownload
} from "./browser-input.js"
import {
  callLocatorFunction,
  evaluateLocatorReadOnly,
  locatorBackendNodeIds,
  locatorIsVisible,
  releaseElement,
  resolveLocatorElement
} from "./browser-locators.js"
import { snapshotPage } from "./browser-snapshot.js"
import type { BrowserToolInvocation, BrowserToolSessionState } from "./browser-use-invoke-types.js"

/// The Playwright-style locator operations (`playwright.*`).
/// Returns undefined for tool names this family does not own.
export const invokePlaywrightTools = async (
  invocation: BrowserToolInvocation,
  state: BrowserToolSessionState
): Promise<CallToolResult | undefined> => {
  const { active, args, backend, cursor, page, toolName } = invocation
  const { downloadsDir } = state
  switch (toolName) {
    case "playwright.domSnapshot":
      return snapshotPage(active, page, 60)
    case "playwright.count": {
      const ids = await locatorBackendNodeIds(active, page, args.locator)
      return jsonResult({ count: ids.length })
    }
    case "playwright.allTextContents": {
      const ids = await locatorBackendNodeIds(active, page, args.locator)
      const values: string[] = []
      for (const id of ids) {
        const resolved = await active.connection.send<{ object: { objectId?: string } }>(
          "DOM.resolveNode",
          { backendNodeId: id },
          page.sessionId
        )
        const objectId = resolved.object.objectId
        if (objectId === undefined) continue
        try {
          values.push(
            evaluatedValue<string>(
              await active.connection.send(
                "Runtime.callFunctionOn",
                {
                  objectId,
                  functionDeclaration: "function(){return String(this.textContent??'');}",
                  returnByValue: true
                },
                page.sessionId
              )
            )
          )
        } finally {
          await active.connection
            .send("Runtime.releaseObject", { objectId }, page.sessionId)
            .catch(() => undefined)
        }
      }
      return jsonResult({ values })
    }
    case "playwright.evaluate": {
      const source = stringArgument(args, "function")
      return jsonResult({
        value:
          args.locator === undefined
            ? await evaluateReadOnly(active, page, source, args.arg)
            : await evaluateLocatorReadOnly(active, page, args.locator, source, args.arg)
      })
    }
    case "playwright.downloadMedia": {
      const element = await resolveLocatorElement(
        active,
        page,
        args.locator,
        false,
        Number(args.timeoutMs ?? 30_000)
      )
      try {
        await triggerMediaDownload(active, page, element.objectId)
      } finally {
        await releaseElement(active, page, element)
      }
      return actionResult(active, page, "playwright.downloadMedia")
    }
    case "playwright.waitForEvent": {
      const event = stringArgument(args, "event")
      const timeoutMs = Math.max(0, Math.min(30_000, Number(args.timeoutMs ?? 30_000)))
      if (event === "filechooser") {
        await active.connection.send(
          "Page.setInterceptFileChooserDialog",
          { enabled: true },
          page.sessionId
        )
        const opened = await waitForCdpEvent(
          active,
          "Page.fileChooserOpened",
          page.sessionId,
          timeoutMs
        )
        const backendNodeId = Number(opened.backendNodeId)
        if (!Number.isInteger(backendNodeId)) {
          throw new Error("The file chooser did not identify its file input")
        }
        const chooserId = randomUUID()
        active.fileChoosers.set(chooserId, { sessionId: page.sessionId, backendNodeId })
        return jsonResult({
          event,
          chooserId,
          multiple: opened.mode === "selectMultiple"
        })
      }
      if (event === "download") {
        const eventSessionId = backend === "extension" ? page.sessionId : undefined
        const eventPromise = waitForCdpEvent(
          active,
          "Browser.downloadWillBegin",
          eventSessionId,
          timeoutMs
        )
        if (backend === "extension") {
          await active.connection.send("Codevisor.armDownload", { timeoutMs }, page.sessionId)
        } else {
          await active.connection.send("Browser.setDownloadBehavior", {
            behavior: "allowAndName",
            downloadPath: downloadsDir,
            eventsEnabled: true
          })
        }
        const download = await eventPromise
        const guid = String(download.guid ?? randomUUID())
        const existing = active.downloads.get(guid)
        const value = {
          guid,
          url: String(download.url ?? ""),
          suggestedFilename: String(download.suggestedFilename ?? "download"),
          ...(typeof download.filePath === "string" ? { path: download.filePath } : {}),
          ...existing
        }
        active.downloads.set(guid, value)
        return jsonResult({ event, downloadId: guid, ...value })
      }
      throw new Error("event must be filechooser or download")
    }
    case "playwright.fileChooserSetFiles": {
      if (!Array.isArray(args.paths) || !args.paths.every((value) => typeof value === "string")) {
        throw new Error("paths must be an array of workspace file paths")
      }
      const chooserId = stringArgument(args, "chooserId")
      const chooser = active.fileChoosers.get(chooserId)
      if (chooser === undefined) throw new Error("Unknown or expired file chooser")
      await active.connection.send(
        "DOM.setFileInputFiles",
        { files: args.paths, backendNodeId: chooser.backendNodeId },
        chooser.sessionId
      )
      active.fileChoosers.delete(chooserId)
      await active.connection
        .send("Page.setInterceptFileChooserDialog", { enabled: false }, chooser.sessionId)
        .catch(() => undefined)
      return jsonResult({ fileCount: args.paths.length })
    }
    case "playwright.downloadPath": {
      const downloadId = stringArgument(args, "downloadId")
      const deadline = Date.now() + Math.max(0, Math.min(30_000, Number(args.timeoutMs ?? 30_000)))
      while (true) {
        const download = active.downloads.get(downloadId)
        if (download?.state === "canceled") throw new Error("Download was canceled")
        if (download?.state === "completed") {
          return jsonResult({ path: download.path ?? join(downloadsDir, downloadId) })
        }
        if (Date.now() >= deadline) throw new Error("Timed out waiting for download")
        await delay(100)
      }
    }
    case "playwright.click": {
      const element = await resolveLocatorElement(
        active,
        page,
        args.locator,
        args.force !== true,
        Number(args.timeoutMs ?? 30_000)
      )
      try {
        await dispatchClick(
          active,
          page,
          element.x,
          element.y,
          String(args.button ?? "left"),
          args.doubleClick === true ? 2 : 1,
          mouseModifierMask(args.modifiers),
          cursor
        )
      } finally {
        await releaseElement(active, page, element)
      }
      return actionResult(active, page, "playwright.click", { addressing: "locator" })
    }
    case "playwright.fill": {
      const value = stringArgument(args, "value")
      const element = await resolveLocatorElement(
        active,
        page,
        args.locator,
        true,
        Number(args.timeoutMs ?? 30_000)
      )
      let actual: string | undefined
      try {
        await cursor.move(element.x, element.y)
        actual = await fillResolvedElement(active, page, element, value, false, true)
      } finally {
        await releaseElement(active, page, element)
      }
      return verifiedActionResult(active, page, "playwright.fill", { value: actual })
    }
    case "playwright.type": {
      const value = stringArgument(args, "value")
      const element = await resolveLocatorElement(
        active,
        page,
        args.locator,
        true,
        Number(args.timeoutMs ?? 30_000)
      )
      try {
        await cursor.move(element.x, element.y)
        await fillResolvedElement(active, page, element, value, false, false)
      } finally {
        await releaseElement(active, page, element)
      }
      return actionResult(active, page, "playwright.type")
    }
    case "playwright.press": {
      const element = await resolveLocatorElement(
        active,
        page,
        args.locator,
        true,
        Number(args.timeoutMs ?? 30_000)
      )
      try {
        await active.connection.send(
          "Runtime.callFunctionOn",
          {
            objectId: element.objectId,
            functionDeclaration: "function(){this.focus();}",
            returnByValue: true
          },
          page.sessionId
        )
        await pressKey(active, page, stringArgument(args, "key"))
      } finally {
        await releaseElement(active, page, element)
      }
      return actionResult(active, page, "playwright.press", { key: args.key })
    }
    case "playwright.check":
    case "playwright.uncheck":
    case "playwright.setChecked": {
      const desired =
        toolName === "playwright.check"
          ? true
          : toolName === "playwright.uncheck"
            ? false
            : booleanArgument(args, "checked")
      const element = await resolveLocatorElement(
        active,
        page,
        args.locator,
        args.force !== true,
        Number(args.timeoutMs ?? 30_000)
      )
      try {
        await setCheckedElement(active, page, element, desired, cursor)
      } finally {
        await releaseElement(active, page, element)
      }
      return verifiedActionResult(active, page, toolName, { checked: desired })
    }
    case "playwright.selectOption": {
      if (!Array.isArray(args.values)) throw new Error("values must be an array")
      const element = await resolveLocatorElement(
        active,
        page,
        args.locator,
        true,
        Number(args.timeoutMs ?? 30_000)
      )
      let selected: string[]
      try {
        await cursor.move(element.x, element.y)
        selected = await selectOptionsElement(active, page, element, args.values)
      } finally {
        await releaseElement(active, page, element)
      }
      return jsonResult({ selected, verified: true })
    }
    case "playwright.isVisible":
      return jsonResult({ visible: await locatorIsVisible(active, page, args.locator) })
    case "playwright.isEnabled":
      return jsonResult({
        enabled: await callLocatorFunction<boolean>(
          active,
          page,
          args.locator,
          "function(){return !this.disabled&&this.getAttribute('aria-disabled')!=='true';}",
          [],
          Number(args.timeoutMs ?? 30_000)
        )
      })
    case "playwright.getAttribute":
      return jsonResult({
        value: await callLocatorFunction<string | null>(
          active,
          page,
          args.locator,
          "function(name){return this.getAttribute(name);}",
          [stringArgument(args, "name")],
          Number(args.timeoutMs ?? 30_000)
        )
      })
    case "playwright.innerText":
      return jsonResult({
        value: await callLocatorFunction<string>(
          active,
          page,
          args.locator,
          "function(){return String(this.innerText||'');}",
          [],
          Number(args.timeoutMs ?? 30_000)
        )
      })
    case "playwright.textContent":
      return jsonResult({
        value: await callLocatorFunction<string | null>(
          active,
          page,
          args.locator,
          "function(){return this.textContent; }",
          [],
          Number(args.timeoutMs ?? 30_000)
        )
      })
    case "playwright.waitFor": {
      const state = stringArgument(args, "state")
      if (!["attached", "detached", "visible", "hidden"].includes(state)) {
        throw new Error("state must be attached, detached, visible, or hidden")
      }
      const timeoutMs = Math.max(0, Math.min(30_000, Number(args.timeoutMs ?? 30_000)))
      const deadline = Date.now() + timeoutMs
      while (true) {
        const ids = await locatorBackendNodeIds(active, page, args.locator)
        const satisfied =
          state === "attached"
            ? ids.length > 0
            : state === "detached"
              ? ids.length === 0
              : state === "visible"
                ? ids.length === 1 && (await locatorIsVisible(active, page, args.locator))
                : ids.length === 0 ||
                  (ids.length === 1 && !(await locatorIsVisible(active, page, args.locator)))
        if (satisfied) return jsonResult({ state, matched: true })
        if (ids.length > 1) {
          throw new Error(
            `Playwright strict mode violation: locator resolved to ${ids.length} elements`
          )
        }
        if (Date.now() >= deadline) {
          throw new Error(`Timed out waiting for locator to become ${state}`)
        }
        await delay(100)
      }
    }
    case "playwright.waitForTimeout":
      await delay(Math.max(0, Math.min(30_000, numberArgument(args, "timeoutMs"))))
      return jsonResult({ waited: true })
    case "playwright.waitForURL": {
      const expected = stringArgument(args, "url")
      const timeoutMs = Math.max(0, Math.min(30_000, Number(args.timeoutMs ?? 30_000)))
      const waitUntil = typeof args.waitUntil === "string" ? args.waitUntil : "commit"
      const deadline = Date.now() + timeoutMs
      while (true) {
        const info = await pageInformation(active, page)
        if (info.url === expected) {
          if (waitUntil === "domcontentloaded") await waitForReady(active, page)
          if (waitUntil === "load" || waitUntil === "networkidle") {
            while ((await evaluate<string>(active, page, "document.readyState")) !== "complete") {
              if (Date.now() >= deadline) {
                throw new Error(`Timed out waiting for URL ${expected}`)
              }
              await delay(100)
            }
            if (waitUntil === "networkidle") await delay(500)
          }
          return jsonResult({ url: info.url, matched: true })
        }
        if (Date.now() >= deadline) throw new Error(`Timed out waiting for URL ${expected}`)
        await delay(100)
      }
    }
    case "playwright.waitForLoadState": {
      const state = typeof args.state === "string" ? args.state : "load"
      if (!["domcontentloaded", "load", "networkidle"].includes(state)) {
        throw new Error("state must be domcontentloaded, load, or networkidle")
      }
      const timeoutMs = Math.max(0, Math.min(30_000, Number(args.timeoutMs ?? 30_000)))
      const deadline = Date.now() + timeoutMs
      while (true) {
        const readyState = await evaluate<string>(active, page, "document.readyState")
        const ready =
          state === "domcontentloaded"
            ? readyState === "interactive" || readyState === "complete"
            : readyState === "complete"
        if (ready) {
          if (state === "networkidle") await delay(500)
          return jsonResult({ state, matched: true })
        }
        if (Date.now() >= deadline) {
          throw new Error(`Timed out waiting for load state ${state}`)
        }
        await delay(100)
      }
    }
    default:
      return undefined
  }
}
