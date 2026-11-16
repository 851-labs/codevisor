import { randomUUID } from "node:crypto"

import type { CallToolResult } from "@modelcontextprotocol/server"

import {
  actionResult,
  booleanArgument,
  evaluateReadOnly,
  jsonResult,
  numberArgument,
  stringArgument,
  verifiedActionResult,
  waitForCdpEvent
} from "./browser-cdp-engine.js"
import { delay, evaluatedValue } from "./browser-cdp.js"
import { namedDownloadPath } from "./browser-downloads.js"
import { setFileChooserFiles, waitForFileChooser } from "./browser-file-chooser.js"
import { routeBrowserFrame } from "./browser-frame.js"
import {
  dispatchClick,
  fillResolvedElement,
  mouseModifierMask,
  pressKey,
  selectOptionsElement,
  setCheckedElement,
  triggerMediaDownload
} from "./browser-input.js"
import { browserNavigationBaseline, waitForBrowserState } from "./browser-load-state.js"
import {
  callLocatorFunction,
  evaluateLocatorReadOnly,
  evaluateAllLocators,
  locatorBackendNodeIds,
  locatorIsVisible,
  releaseElement,
  resolveLocatorElement
} from "./browser-locators.js"
import { snapshotPage } from "./browser-snapshot.js"
import type { BrowserToolInvocation, BrowserToolSessionState } from "./browser-use-invoke-types.js"
import { waitBudget } from "./browser-wait-budget.js"
import { expectString } from "./unknown-values.js"

const typedKeyName = (character: string): string => {
  if (character === " ") return "Space"
  if (character === "\n") return "Enter"
  return character
}

const desiredCheckedState = (
  toolName: string,
  args: Readonly<Record<string, unknown>>
): boolean => {
  if (toolName === "playwright.check") return true
  if (toolName === "playwright.uncheck") return false
  return booleanArgument(args, "checked")
}

export const invokePlaywrightTools = async (
  invocation: BrowserToolInvocation,
  state: BrowserToolSessionState
): Promise<CallToolResult | undefined> => {
  const { active, backend, cursor, toolName } = invocation
  let { args, page } = invocation
  if (args.locator !== undefined) {
    const routed = await routeBrowserFrame(active, page, args.locator)
    page = routed.page
    args = { ...args, locator: routed.locator }
  }
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
            expectString(
              evaluatedValue(
                await active.connection.send(
                  "Runtime.callFunctionOn",
                  {
                    objectId,
                    functionDeclaration: "function(){return String(this.textContent??'');}",
                    returnByValue: true
                  },
                  page.sessionId
                )
              ),
              "Locator text"
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
    case "playwright.evaluateAll":
      return jsonResult({
        value: await evaluateAllLocators(
          active,
          page,
          args.locator,
          stringArgument(args, "function"),
          args.arg
        )
      })
    case "playwright.pressSequentially": {
      const element = await resolveLocatorElement(
        active,
        page,
        args.locator,
        true,
        waitBudget(args.timeoutMs)
      )
      try {
        await active.connection.send(
          "Runtime.callFunctionOn",
          {
            objectId: element.objectId,
            functionDeclaration: "function(){this.focus()}",
            returnByValue: true
          },
          page.sessionId
        )
        for (const character of stringArgument(args, "value"))
          await pressKey(active, page, typedKeyName(character))
      } finally {
        await releaseElement(active, page, element)
      }
      return actionResult(active, page, "playwright.pressSequentially")
    }
    case "playwright.evaluate": {
      const source = stringArgument(args, "function")
      let value: unknown
      if (args.locator === undefined) {
        value = await evaluateReadOnly(active, page, source, args.arg)
      } else {
        value = await evaluateLocatorReadOnly(active, page, args.locator, source, args.arg)
      }
      return jsonResult({ value })
    }
    case "playwright.downloadMedia": {
      const element = await resolveLocatorElement(
        active,
        page,
        args.locator,
        false,
        waitBudget(args.timeoutMs)
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
      const timeoutMs = waitBudget(args.timeoutMs)
      if (event === "filechooser") return waitForFileChooser(active, page, timeoutMs)
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
        const guid = typeof download.guid === "string" ? download.guid : randomUUID()
        const existing = active.downloads.get(guid)
        const value = {
          guid,
          url: typeof download.url === "string" ? download.url : "",
          suggestedFilename:
            typeof download.suggestedFilename === "string"
              ? download.suggestedFilename
              : "download",
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
      return setFileChooserFiles(active, stringArgument(args, "chooserId"), args.paths)
    }
    case "playwright.downloadPath": {
      const downloadId = stringArgument(args, "downloadId")
      const deadline = Date.now() + waitBudget(args.timeoutMs)
      while (true) {
        const download = active.downloads.get(downloadId)
        if (download?.state === "canceled") throw new Error("Download was canceled")
        if (download?.state === "completed") {
          return jsonResult({ path: namedDownloadPath(downloadsDir, download) })
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
        waitBudget(args.timeoutMs)
      )
      try {
        await dispatchClick(
          active,
          page,
          element.x,
          element.y,
          typeof args.button === "string" ? args.button : "left",
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
        waitBudget(args.timeoutMs)
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
        waitBudget(args.timeoutMs)
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
        waitBudget(args.timeoutMs)
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
      const desired = desiredCheckedState(toolName, args)
      const element = await resolveLocatorElement(
        active,
        page,
        args.locator,
        args.force !== true,
        waitBudget(args.timeoutMs)
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
        waitBudget(args.timeoutMs)
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
        enabled: await callLocatorFunction(
          active,
          page,
          args.locator,
          "function(){return !this.disabled&&this.getAttribute('aria-disabled')!=='true';}",
          [],
          waitBudget(args.timeoutMs)
        )
      })
    case "playwright.getAttribute":
      return jsonResult({
        value: await callLocatorFunction(
          active,
          page,
          args.locator,
          "function(name){return this.getAttribute(name);}",
          [stringArgument(args, "name")],
          waitBudget(args.timeoutMs)
        )
      })
    case "playwright.innerText":
      return jsonResult({
        value: await callLocatorFunction(
          active,
          page,
          args.locator,
          "function(){return String(this.innerText||'');}",
          [],
          waitBudget(args.timeoutMs)
        )
      })
    case "playwright.textContent":
      return jsonResult({
        value: await callLocatorFunction(
          active,
          page,
          args.locator,
          "function(){return this.textContent; }",
          [],
          waitBudget(args.timeoutMs)
        )
      })
    case "playwright.waitFor": {
      const targetState = stringArgument(args, "state")
      if (!["attached", "detached", "visible", "hidden"].includes(targetState)) {
        throw new Error("state must be attached, detached, visible, or hidden")
      }
      const deadline = Date.now() + waitBudget(args.timeoutMs)
      while (true) {
        const ids = await locatorBackendNodeIds(active, page, args.locator)
        let satisfied: boolean
        if (targetState === "attached") satisfied = ids.length > 0
        else if (targetState === "detached") satisfied = ids.length === 0
        else if (targetState === "visible")
          satisfied = ids.length === 1 && (await locatorIsVisible(active, page, args.locator))
        else
          satisfied =
            ids.length === 0 ||
            (ids.length === 1 && !(await locatorIsVisible(active, page, args.locator)))
        if (satisfied) return jsonResult({ state: targetState, matched: true })
        if (ids.length > 1) {
          throw new Error(
            `Playwright strict mode violation: locator resolved to ${ids.length} elements`
          )
        }
        if (Date.now() >= deadline) {
          throw new Error(`Timed out waiting for locator to become ${targetState}`)
        }
        await delay(100)
      }
    }
    case "playwright.waitForTimeout":
      await delay(waitBudget(numberArgument(args, "timeoutMs")))
      return jsonResult({ waited: true })
    case "playwright.armNavigation":
      return jsonResult(await browserNavigationBaseline(active, page))
    case "playwright.waitForNavigation":
      await waitForBrowserState(active, page, {
        state: typeof args.waitUntil === "string" ? args.waitUntil : "load",
        timeoutMs: waitBudget(args.timeoutMs),
        afterSequence: Number(args.afterSequence),
        frameId: String(args.frameId),
        ...(typeof args.url === "string" ? { url: args.url } : {})
      })
      return jsonResult({ navigated: true })
    case "playwright.waitForURL":
      await waitForBrowserState(active, page, {
        url: stringArgument(args, "url"),
        state: typeof args.waitUntil === "string" ? args.waitUntil : "commit",
        timeoutMs: waitBudget(args.timeoutMs)
      })
      return jsonResult({ matched: true })
    case "playwright.waitForLoadState":
      await waitForBrowserState(active, page, {
        state: typeof args.state === "string" ? args.state : "load",
        timeoutMs: waitBudget(args.timeoutMs)
      })
      return jsonResult({ matched: true })
    default:
      return undefined
  }
}
