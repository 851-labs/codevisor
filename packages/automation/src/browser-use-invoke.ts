import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"
import { randomUUID } from "node:crypto"
import { mkdirSync, writeFileSync } from "node:fs"
import { basename, join } from "node:path"
import type { AutomationProviderContext } from "./automation-provider.js"
import { delay, evaluatedValue } from "./browser-cdp.js"
import {
  actionResult,
  attachTarget,
  booleanArgument,
  currentPage,
  discardTargetState,
  evaluate,
  evaluateReadOnly,
  grantClipboardPermissions,
  jsonResult,
  numberArgument,
  pageInformation,
  pageResult,
  pageTargets,
  stringArgument,
  verifiedActionResult,
  waitForCdpEvent,
  waitForCreatedTarget,
  waitForReady,
  type BrowserRuntime,
  type ResolvedElement,
  type TargetInfo
} from "./browser-cdp-engine.js"
import {
  dispatchClick,
  fillElement,
  fillResolvedElement,
  mediaElementAtPoint,
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
  resolveElement,
  resolveLocatorElement
} from "./browser-locators.js"
import { normalizeRef, snapshotPage } from "./browser-snapshot.js"
import type { BrowserBackend } from "./browser-use-provider.js"

export interface BrowserAssetInventory {
  readonly pageUrl: string
  readonly assets: ReadonlyArray<{
    readonly id: string
    readonly url: string
    readonly kind: string
    readonly name: string
    readonly sources: ReadonlyArray<Readonly<Record<string, unknown>>>
  }>
  readonly inlineSvgs: ReadonlyArray<{
    readonly id: string
    readonly markup: string
    readonly name: string
  }>
}

export interface BrowserToolSessionState {
  readonly assetInventories: Map<string, BrowserAssetInventory>
  readonly assetsDir: string
  readonly downloadsDir: string
  readonly selectedTargets: Map<string, string>
  readonly sessionBackends: Map<string, BrowserBackend>
  readonly sessionDispositions: Map<string, Map<string, "deliverable" | "handoff">>
  readonly sessionTargets: Map<string, Map<string, "created" | "claimed">>
}

export const runtimeKey = (context: AutomationProviderContext, backend: BrowserBackend): string =>
  backend === "managed" ? `managed:${context.projectId ?? "global"}` : "extension"

export const makeBrowserToolInvoker = (state: BrowserToolSessionState) => {
  const {
    assetInventories,
    assetsDir,
    downloadsDir,
    selectedTargets,
    sessionBackends,
    sessionDispositions,
    sessionTargets
  } = state
  return async (
    context: AutomationProviderContext,
    active: BrowserRuntime,
    toolName: string,
    args: Readonly<Record<string, unknown>>
  ): Promise<CallToolResult> => {
    const backend = sessionBackends.get(context.sessionId) ?? "managed"
    const sessionKey = `${runtimeKey(context, backend)}:${context.sessionId}`
    if (toolName === "finalizeTabs") {
      if (args.native === true) {
        if (
          args.keepIds !== undefined &&
          (!Array.isArray(args.keepIds) ||
            !args.keepIds.every((value) => typeof value === "string"))
        ) {
          throw new Error("keepIds must be an array of tab ids")
        }
        const keepIds = new Set([
          ...((args.keepIds as string[] | undefined) ?? []),
          ...(sessionDispositions.get(sessionKey)?.keys() ?? [])
        ])
        const controlled = sessionTargets.get(sessionKey) ?? new Map()
        for (const [targetId, origin] of controlled) {
          const tabSessionId = active.sessions.get(targetId)
          if (origin === "created" && !keepIds.has(targetId)) {
            await active.connection.send("Target.closeTarget", { targetId }).catch(() => undefined)
          } else if (tabSessionId !== undefined) {
            await active.connection
              .send("Target.detachFromTarget", { sessionId: tabSessionId })
              .catch(() => undefined)
          }
          discardTargetState(active, targetId)
        }
        sessionTargets.delete(sessionKey)
        sessionDispositions.delete(sessionKey)
        selectedTargets.delete(sessionKey)
        return jsonResult({ finalized: true, kept: [...keepIds] })
      }
      const targetId = selectedTargets.get(sessionKey)
      if (targetId === undefined) return jsonResult({ finalized: true, tabsClosed: false })
      const tabSessionId = active.sessions.get(targetId)
      if (args.close === true) {
        await active.connection.send("Target.closeTarget", { targetId })
      } else if (tabSessionId !== undefined) {
        await active.connection.send("Target.detachFromTarget", { sessionId: tabSessionId })
      }
      discardTargetState(active, targetId)
      sessionTargets.get(sessionKey)?.delete(targetId)
      selectedTargets.delete(sessionKey)
      return jsonResult({ finalized: true, tabsClosed: args.close === true })
    }
    if (toolName === "markTab") {
      const status = stringArgument(args, "status")
      if (status !== "deliverable" && status !== "handoff") {
        throw new Error("status must be deliverable or handoff")
      }
      const targetId = typeof args.id === "string" ? args.id : selectedTargets.get(sessionKey)
      if (targetId === undefined) throw new Error("There is no selected tab to mark")
      const dispositions = sessionDispositions.get(sessionKey) ?? new Map()
      dispositions.set(targetId, status)
      sessionDispositions.set(sessionKey, dispositions)
      return jsonResult({ id: targetId, status })
    }
    if (toolName === "tabs") {
      const action = stringArgument(args, "action")
      let targets: TargetInfo[] | undefined
      if (action === "new") {
        const url = typeof args.url === "string" ? args.url : "about:blank"
        const created = await active.connection.send<{ targetId: string }>("Target.createTarget", {
          url
        })
        selectedTargets.set(sessionKey, created.targetId)
        const controlled = sessionTargets.get(sessionKey) ?? new Map()
        controlled.set(created.targetId, "created")
        sessionTargets.set(sessionKey, controlled)
        targets = await waitForCreatedTarget(active, created.targetId, url)
      } else {
        targets = await pageTargets(active)
        if (action === "select") {
          const id = typeof args.id === "string" ? args.id : undefined
          const index = id === undefined ? numberArgument(args, "index") : undefined
          const target =
            id === undefined
              ? targets[index!]
              : targets.find((candidate) => candidate.targetId === id)
          if (target === undefined) {
            throw new Error(
              id === undefined ? `No browser tab at index ${index}` : `No browser tab with id ${id}`
            )
          }
          selectedTargets.set(sessionKey, target.targetId)
          const controlled = sessionTargets.get(sessionKey) ?? new Map()
          if (!controlled.has(target.targetId)) controlled.set(target.targetId, "claimed")
          sessionTargets.set(sessionKey, controlled)
        } else if (action === "close") {
          const selectedId = selectedTargets.get(sessionKey)
          const id = typeof args.id === "string" ? args.id : undefined
          const index = typeof args.index === "number" ? args.index : undefined
          const target =
            id !== undefined
              ? targets.find((candidate) => candidate.targetId === id)
              : index === undefined
                ? (targets.find((candidate) => candidate.targetId === selectedId) ?? targets[0])
                : targets[index]
          if (target === undefined) throw new Error("There is no browser tab to close")
          await active.connection.send("Target.closeTarget", { targetId: target.targetId })
          if (selectedId === target.targetId) selectedTargets.delete(sessionKey)
          discardTargetState(active, target.targetId)
          sessionTargets.get(sessionKey)?.delete(target.targetId)
        } else if (action !== "list")
          throw new Error("tabs.action must be list, new, close, or select")
      }
      targets ??= await pageTargets(active)
      const selectedId = selectedTargets.get(sessionKey)
      return jsonResult({
        tabs: targets.map((target, index) => ({
          id: target.targetId,
          index,
          selected: target.targetId === selectedId,
          title: target.title,
          url: target.url
        }))
      })
    }
    if (toolName === "user.history") {
      if (backend !== "extension") {
        throw new Error("Browser history is only available with the user Chrome backend")
      }
      const toTimestamp = (value: unknown): number | undefined => {
        if (typeof value === "number" && Number.isFinite(value)) return value
        if (typeof value !== "string") return undefined
        const parsed = Date.parse(value)
        if (Number.isNaN(parsed)) throw new Error(`Invalid history date: ${value}`)
        return parsed
      }
      const raw = await active.connection.send<{
        entries?: Array<{ url?: string; title?: string; lastVisitTime?: number }>
      }>("Codevisor.getHistory", {
        text:
          Array.isArray(args.queries) && args.queries.every((query) => typeof query === "string")
            ? args.queries.join(" ")
            : "",
        ...(toTimestamp(args.from) === undefined ? {} : { startTime: toTimestamp(args.from) }),
        ...(toTimestamp(args.to) === undefined ? {} : { endTime: toTimestamp(args.to) }),
        maxResults: typeof args.limit === "number" ? Math.max(1, Math.min(1_000, args.limit)) : 100
      })
      return jsonResult({
        entries: (raw.entries ?? [])
          .filter((entry): entry is typeof entry & { url: string } => typeof entry.url === "string")
          .map((entry) => ({
            url: entry.url,
            dateVisited: new Date(entry.lastVisitTime ?? 0).toISOString(),
            ...(typeof entry.title === "string" ? { title: entry.title } : {})
          }))
      })
    }

    const page = await currentPage(active, selectedTargets, sessionKey)
    switch (toolName) {
      case "tab_info": {
        const info = await pageInformation(active, page)
        return jsonResult({ id: page.target.targetId, ...info })
      }
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
        const deadline =
          Date.now() + Math.max(0, Math.min(30_000, Number(args.timeoutMs ?? 30_000)))
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
            mouseModifierMask(args.modifiers)
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
          await setCheckedElement(active, page, element, desired)
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
      case "clipboard.readText": {
        if (backend === "extension") {
          const value = await active.connection.send<{ text?: string }>(
            "Codevisor.clipboard.readText"
          )
          return jsonResult({ text: String(value.text ?? "") })
        }
        await grantClipboardPermissions(active, page)
        const value = await evaluateReadOnly<string>(
          active,
          page,
          "async () => await navigator.clipboard.readText()",
          undefined
        )
        return jsonResult({ text: value })
      }
      case "clipboard.writeText": {
        const text = stringArgument(args, "text")
        if (backend === "extension") {
          await active.connection.send("Codevisor.clipboard.writeText", { text })
          return jsonResult({ written: true })
        }
        await grantClipboardPermissions(active, page)
        await active.connection.send(
          "Runtime.evaluate",
          {
            expression: `navigator.clipboard.writeText(${JSON.stringify(text)})`,
            awaitPromise: true,
            userGesture: true,
            returnByValue: true
          },
          page.sessionId
        )
        return jsonResult({ written: true })
      }
      case "clipboard.read": {
        if (backend === "extension") {
          const value = await active.connection.send<{ items?: unknown[] }>(
            "Codevisor.clipboard.read"
          )
          return jsonResult({ items: value.items ?? [] })
        }
        await grantClipboardPermissions(active, page)
        const rawItems = await evaluateReadOnly<
          Array<{ readonly types: string[]; readonly data: Readonly<Record<string, string>> }>
        >(
          active,
          page,
          "async () => Promise.all((await navigator.clipboard.read()).map(async item => ({types:[...item.types],data:Object.fromEntries(await Promise.all(item.types.map(async type=>{const bytes=new Uint8Array(await (await item.getType(type)).arrayBuffer());let binary='';for(let index=0;index<bytes.length;index+=0x8000)binary+=String.fromCharCode(...bytes.subarray(index,index+0x8000));return [type,btoa(binary)];})))})))",
          undefined
        )
        return jsonResult({
          items: rawItems.map((item) => ({
            entries: item.types.map((mimeType) => {
              const base64 = item.data[mimeType] ?? ""
              return mimeType.startsWith("text/")
                ? { mimeType, text: Buffer.from(base64, "base64").toString("utf8") }
                : { mimeType, base64 }
            })
          }))
        })
      }
      case "clipboard.write": {
        if (!Array.isArray(args.items)) throw new Error("items must be an array")
        if (backend === "extension") {
          await active.connection.send("Codevisor.clipboard.write", { items: args.items })
          return jsonResult({ written: true })
        }
        await grantClipboardPermissions(active, page)
        await active.connection.send(
          "Runtime.evaluate",
          {
            expression: `(async(items)=>navigator.clipboard.write(items.map(item=>new ClipboardItem(Object.fromEntries((item.entries??[]).map(entry=>{if(typeof entry.text==='string')return[entry.mimeType,new Blob([entry.text],{type:entry.mimeType})];const binary=atob(entry.base64??''),bytes=Uint8Array.from(binary,char=>char.charCodeAt(0));return[entry.mimeType,new Blob([bytes],{type:entry.mimeType})]})),{presentationStyle:item.presentationStyle}))))(${JSON.stringify(args.items)})`,
            awaitPromise: true,
            userGesture: true,
            returnByValue: true
          },
          page.sessionId
        )
        return jsonResult({ written: true })
      }
      case "dev.logs": {
        const levels =
          Array.isArray(args.levels) && args.levels.every((level) => typeof level === "string")
            ? new Set(args.levels.map((level) => (level === "warning" ? "warn" : level)))
            : undefined
        const filter = typeof args.filter === "string" ? args.filter : undefined
        const normalized = (active.logs.get(page.sessionId) ?? []).map((entry) => {
          if (entry.method === "Runtime.consoleAPICalled") {
            const args = Array.isArray(entry.args)
              ? (entry.args as Array<Readonly<Record<string, unknown>>>)
              : []
            const message = args
              .map((value) => String(value.value ?? value.description ?? value.type ?? ""))
              .join(" ")
            return {
              level: entry.type === "warning" ? "warn" : String(entry.type ?? "log"),
              message,
              timestamp: new Date(Number(entry.timestamp ?? Date.now())).toISOString()
            }
          }
          if (entry.method === "Log.entryAdded") {
            const value =
              entry.entry !== null && typeof entry.entry === "object"
                ? (entry.entry as Readonly<Record<string, unknown>>)
                : {}
            return {
              level: value.level === "warning" ? "warn" : String(value.level ?? "log"),
              message: String(value.text ?? ""),
              timestamp: new Date(Number(value.timestamp ?? Date.now())).toISOString(),
              ...(typeof value.url === "string" ? { url: value.url } : {})
            }
          }
          const detail =
            entry.exceptionDetails !== null && typeof entry.exceptionDetails === "object"
              ? (entry.exceptionDetails as Readonly<Record<string, unknown>>)
              : {}
          const exception =
            detail.exception !== null && typeof detail.exception === "object"
              ? (detail.exception as Readonly<Record<string, unknown>>)
              : {}
          return {
            level: "error",
            message: String(exception.description ?? detail.text ?? "Uncaught page error"),
            timestamp: new Date(Number(entry.timestamp ?? Date.now())).toISOString(),
            ...(typeof detail.url === "string" ? { url: detail.url } : {})
          }
        })
        const entries = normalized
          .filter(
            (entry) =>
              (levels === undefined || levels.has(entry.level)) &&
              (filter === undefined || entry.message.includes(filter))
          )
          .slice(-Math.max(1, Math.min(1_000, Number(args.limit ?? 100))))
        return jsonResult({ entries })
      }
      case "getJsDialog":
        return jsonResult({ dialog: active.dialogs.get(page.sessionId) ?? null })
      case "viewport.set": {
        const width = Math.round(numberArgument(args, "width"))
        const height = Math.round(numberArgument(args, "height"))
        await active.connection.send(
          "Emulation.setDeviceMetricsOverride",
          { width, height, deviceScaleFactor: 1, mobile: false },
          page.sessionId
        )
        return jsonResult({ width, height })
      }
      case "viewport.reset":
        await active.connection.send("Emulation.clearDeviceMetricsOverride", {}, page.sessionId)
        return jsonResult({ reset: true })
      case "cdp.send": {
        const method = stringArgument(args, "method")
        const target =
          args.target !== null && typeof args.target === "object"
            ? (args.target as Readonly<Record<string, unknown>>)
            : undefined
        let sessionId = page.sessionId
        if (typeof target?.sessionId === "string") sessionId = target.sessionId
        if (typeof target?.targetId === "string") {
          sessionId = await attachTarget(active, target.targetId)
        }
        const params =
          args.params !== null && typeof args.params === "object" && !Array.isArray(args.params)
            ? (args.params as Readonly<Record<string, unknown>>)
            : {}
        const timeoutMs = Math.max(0, Math.min(30_000, Number(args.timeoutMs ?? 30_000)))
        return jsonResult({
          result: await active.connection.send(method, params, sessionId, timeoutMs)
        })
      }
      case "cdp.readEvents": {
        const afterSequence =
          typeof args.afterSequence === "number"
            ? Math.max(0, args.afterSequence)
            : active.eventSequence
        const limit = Math.max(1, Math.min(1_000, Number(args.limit ?? 100)))
        const methods =
          Array.isArray(args.methods) && args.methods.every((method) => typeof method === "string")
            ? new Set(args.methods)
            : undefined
        const target =
          args.target !== null && typeof args.target === "object"
            ? (args.target as Readonly<Record<string, unknown>>)
            : undefined
        const targetSession =
          typeof target?.sessionId === "string"
            ? target.sessionId
            : typeof target?.targetId === "string"
              ? active.sessions.get(target.targetId)
              : page.sessionId
        const matches = () =>
          active.eventLog.filter((event) => {
            const eventSessionId =
              event.sessionId ??
              (event.method === "Target.detachedFromTarget" &&
              typeof event.params.sessionId === "string"
                ? event.params.sessionId
                : undefined)
            return (
              event.sequence > afterSequence &&
              (methods === undefined || methods.has(event.method)) &&
              (targetSession === undefined || eventSessionId === targetSession)
            )
          })
        const timeoutMs = Math.max(0, Math.min(30_000, Number(args.timeoutMs ?? 0)))
        const deadline = Date.now() + timeoutMs
        while (matches().length === 0 && Date.now() < deadline) await delay(50)
        const all = matches()
        const events = all.slice(0, limit).map((event) => {
          const eventSessionId =
            event.sessionId ??
            (event.method === "Target.detachedFromTarget" &&
            typeof event.params.sessionId === "string"
              ? event.params.sessionId
              : undefined)
          return {
            method: event.method,
            params: event.params,
            sequence: event.sequence,
            source: {
              ...(eventSessionId === undefined ? {} : { sessionId: eventSessionId }),
              targetId:
                [...active.sessions.entries()].find(
                  ([, sessionId]) => sessionId === eventSessionId
                )?.[0] ??
                (eventSessionId === undefined
                  ? undefined
                  : active.staleSessions.get(eventSessionId)) ??
                page.target.targetId
            }
          }
        })
        return jsonResult({
          cursor: events.at(-1)?.sequence ?? active.eventSequence,
          events,
          hasMore: all.length > events.length,
          truncated: active.eventLog.length > 0 && afterSequence < active.eventLog[0]!.sequence - 1
        })
      }
      case "pageAssets.list": {
        const inventory = await evaluate<{
          pageUrl: string
          assets: Array<{ url: string; kind: string }>
          inlineSvgs: Array<{ markup: string }>
        }>(
          active,
          page,
          `(()=>{const urls=new Map();const classify=kind=>kind==='img'?'image':kind==='css'||kind==='link'?'stylesheet':kind==='video'||kind==='media'||kind==='audio'||kind==='source'?'video':kind==='script'?'script':kind==='font'?'font':'other';const add=(url,kind)=>{try{const absolute=new URL(url,location.href).href;if(!urls.has(absolute))urls.set(absolute,{url:absolute,kind:classify(kind)});}catch{}};for(const entry of performance.getEntriesByType('resource'))add(entry.name,entry.initiatorType||'other');for(const element of document.querySelectorAll('img[src],video[src],audio[src],source[src],script[src],link[href]'))add(element.src||element.href,element.tagName.toLowerCase());return{pageUrl:location.href,assets:[...urls.values()],inlineSvgs:[...document.querySelectorAll('svg')].map(svg=>({markup:svg.outerHTML}))};})()`
        )
        const id = randomUUID()
        const normalized = {
          pageUrl: inventory.pageUrl,
          assets: inventory.assets.map((asset, index) => ({
            id: `a${index + 1}`,
            ...asset,
            name: (() => {
              try {
                return basename(new URL(asset.url).pathname) || `asset-${index + 1}`
              } catch {
                return `asset-${index + 1}`
              }
            })(),
            sources: [{ kind: "resource" }]
          })),
          inlineSvgs: inventory.inlineSvgs.map((asset, index) => ({
            id: `s${index + 1}`,
            ...asset,
            name: `inline-${index + 1}.svg`
          }))
        }
        assetInventories.set(id, normalized)
        const byKind = Object.fromEntries(
          [...new Set(normalized.assets.map((asset) => asset.kind))].map((kind) => [
            kind,
            normalized.assets.filter((asset) => asset.kind === kind).length
          ])
        )
        return jsonResult({
          id,
          ...normalized,
          summary: {
            byKind,
            inlineSvgCount: normalized.inlineSvgs.length,
            totalCount: normalized.assets.length + normalized.inlineSvgs.length
          }
        })
      }
      case "pageAssets.bundle": {
        const inventoryId = stringArgument(args, "inventoryId")
        const inventory = assetInventories.get(inventoryId)
        if (inventory === undefined) throw new Error("Unknown or expired page asset inventory")
        const selectedIds =
          Array.isArray(args.assetIds) &&
          args.assetIds.every((assetId) => typeof assetId === "string")
            ? new Set(args.assetIds)
            : undefined
        const kinds =
          Array.isArray(args.kinds) && args.kinds.every((kind) => typeof kind === "string")
            ? new Set(args.kinds)
            : undefined
        const bundleDir = join(assetsDir, inventoryId)
        mkdirSync(bundleDir, { recursive: true, mode: 0o700 })
        const saved: Array<{
          contentType: string | null
          id: string
          kind: string
          name: string
          path: string
          url: string
        }> = []
        const failures: Array<{
          contentType: string | null
          id: string
          name: string
          reason: string
          url: string
        }> = []
        const requested = inventory.assets.filter(
          (asset) =>
            (selectedIds === undefined || selectedIds.has(asset.id)) &&
            (kinds === undefined || kinds.has(asset.kind))
        )
        const startedAt = Date.now()
        for (const asset of inventory.assets) {
          if (selectedIds !== undefined && !selectedIds.has(asset.id)) continue
          if (kinds !== undefined && !kinds.has(asset.kind)) continue
          const fetched = await evaluate<{ base64?: string; mimeType?: string; error?: string }>(
            active,
            page,
            `(async()=>{try{const response=await fetch(${JSON.stringify(asset.url)});if(!response.ok)return{error:String(response.status)};const bytes=new Uint8Array(await response.arrayBuffer());let binary='';for(let index=0;index<bytes.length;index+=0x8000)binary+=String.fromCharCode(...bytes.subarray(index,index+0x8000));return{base64:btoa(binary),mimeType:response.headers.get('content-type')||undefined};}catch(error){return{error:String(error)}}})()`
          )
          if (fetched.base64 === undefined) {
            failures.push({
              contentType: fetched.mimeType ?? null,
              id: asset.id,
              name: asset.name,
              reason: fetched.error ?? "Download failed",
              url: asset.url
            })
            continue
          }
          const path = join(
            bundleDir,
            `${asset.id}-${asset.name.replaceAll(/[^a-zA-Z0-9._-]/g, "_")}`
          )
          writeFileSync(path, Buffer.from(fetched.base64, "base64"), { mode: 0o600 })
          saved.push({
            contentType: fetched.mimeType ?? null,
            id: asset.id,
            kind: asset.kind,
            name: asset.name,
            path,
            url: asset.url
          })
        }
        const manifestPath = join(bundleDir, "manifest.json")
        writeFileSync(
          manifestPath,
          JSON.stringify(
            { inventoryId, pageUrl: inventory.pageUrl, assets: saved, failures },
            null,
            2
          ),
          { mode: 0o600 }
        )
        return jsonResult({
          assets: saved,
          directoryPath: bundleDir,
          failures,
          manifestPath,
          summary: {
            downloadedCount: saved.length,
            elapsedMs: Date.now() - startedAt,
            failedCount: failures.length,
            requestedCount: requested.length
          }
        })
      }
      case "navigate": {
        const url = stringArgument(args, "url")
        const response = await active.connection.send<{ errorText?: string }>(
          "Page.navigate",
          { url },
          page.sessionId
        )
        if (response.errorText !== undefined) throw new Error(response.errorText)
        await waitForReady(active, page)
        return pageResult(active, page, { action: "navigate", path: "cdp", delivered: true })
      }
      case "back":
      case "forward": {
        const history = await active.connection.send<{
          currentIndex: number
          entries: Array<{ id: number }>
        }>("Page.getNavigationHistory", {}, page.sessionId)
        const offset = toolName === "back" ? -1 : 1
        const entry = history.entries[history.currentIndex + offset]
        if (entry === undefined) throw new Error(`There is no page to navigate ${toolName}`)
        await active.connection.send(
          "Page.navigateToHistoryEntry",
          { entryId: entry.id },
          page.sessionId
        )
        await waitForReady(active, page)
        return pageResult(active, page, { action: toolName, path: "cdp", delivered: true })
      }
      case "reload":
        await active.connection.send("Page.reload", {}, page.sessionId)
        await waitForReady(active, page)
        return pageResult(active, page, { action: "reload", path: "cdp", delivered: true })
      case "snapshot":
        return snapshotPage(active, page, Math.max(1, Math.min(60, Number(args.depth ?? 30))))
      case "screenshot": {
        const format = args.type === "jpeg" ? "jpeg" : "png"
        let clip: { x: number; y: number; width: number; height: number; scale: number } | undefined
        let element: ResolvedElement | undefined
        if (args.clip !== undefined) {
          if (args.clip === null || typeof args.clip !== "object" || Array.isArray(args.clip)) {
            throw new Error("clip must be an object")
          }
          const requested = args.clip as Readonly<Record<string, unknown>>
          clip = {
            x: numberArgument(requested, "x"),
            y: numberArgument(requested, "y"),
            width: numberArgument(requested, "width"),
            height: numberArgument(requested, "height"),
            scale: 1
          }
        } else if (args.target !== undefined) {
          element = await resolveElement(active, page, args.target, false)
          const metrics = await active.connection.send<{
            cssVisualViewport: { pageX: number; pageY: number }
          }>("Page.getLayoutMetrics", {}, page.sessionId)
          clip = {
            x: metrics.cssVisualViewport.pageX + element.x - element.width / 2,
            y: metrics.cssVisualViewport.pageY + element.y - element.height / 2,
            width: element.width,
            height: element.height,
            scale: 1
          }
        } else if (args.fullPage === true) {
          const metrics = await active.connection.send<{
            contentSize: { x: number; y: number; width: number; height: number }
          }>("Page.getLayoutMetrics", {}, page.sessionId)
          clip = { ...metrics.contentSize, scale: 1 }
        } else {
          const metrics = await active.connection.send<{
            cssVisualViewport: {
              pageX: number
              pageY: number
              clientWidth: number
              clientHeight: number
            }
          }>("Page.getLayoutMetrics", {}, page.sessionId)
          clip = {
            x: metrics.cssVisualViewport.pageX,
            y: metrics.cssVisualViewport.pageY,
            width: metrics.cssVisualViewport.clientWidth,
            height: metrics.cssVisualViewport.clientHeight,
            scale: 1
          }
        }
        try {
          const captured = await active.connection.send<{ data: string }>(
            "Page.captureScreenshot",
            {
              format,
              fromSurface: true,
              captureBeyondViewport: args.fullPage === true,
              clip
            },
            page.sessionId
          )
          const info = await pageInformation(active, page)
          return {
            content: [
              {
                type: "text",
                text: `Page URL: ${info.url}\nScreenshot coordinates are CSS viewport coordinates.`
              },
              { type: "image", data: captured.data, mimeType: `image/${format}` }
            ]
          }
        } finally {
          if (element !== undefined) await releaseElement(active, page, element)
        }
      }
      case "click": {
        const element = await resolveElement(active, page, args.target)
        try {
          await dispatchClick(
            active,
            page,
            element.x,
            element.y,
            String(args.button ?? "left"),
            args.doubleClick === true ? 2 : 1
          )
        } finally {
          await releaseElement(active, page, element)
        }
        return actionResult(active, page, "click", {
          addressing: "element",
          target: normalizeRef(args.target)
        })
      }
      case "hover": {
        const element = await resolveElement(active, page, args.target, false)
        try {
          await active.connection.send(
            "Input.dispatchMouseEvent",
            { type: "mouseMoved", x: element.x, y: element.y },
            page.sessionId
          )
        } finally {
          await releaseElement(active, page, element)
        }
        return actionResult(active, page, "hover", { target: normalizeRef(args.target) })
      }
      case "drag": {
        const start = await resolveElement(active, page, args.startTarget)
        const end = await resolveElement(active, page, args.endTarget)
        try {
          await active.connection.send(
            "Input.dispatchMouseEvent",
            { type: "mouseMoved", x: start.x, y: start.y },
            page.sessionId
          )
          await active.connection.send(
            "Input.dispatchMouseEvent",
            {
              type: "mousePressed",
              x: start.x,
              y: start.y,
              button: "left",
              buttons: 1,
              clickCount: 1
            },
            page.sessionId
          )
          for (let step = 1; step <= 10; step++) {
            const progress = step / 10
            await active.connection.send(
              "Input.dispatchMouseEvent",
              {
                type: "mouseMoved",
                x: start.x + (end.x - start.x) * progress,
                y: start.y + (end.y - start.y) * progress,
                button: "left",
                buttons: 1
              },
              page.sessionId
            )
            await delay(16)
          }
          await active.connection.send(
            "Input.dispatchMouseEvent",
            {
              type: "mouseReleased",
              x: end.x,
              y: end.y,
              button: "left",
              buttons: 0,
              clickCount: 1
            },
            page.sessionId
          )
        } finally {
          await Promise.all([
            releaseElement(active, page, start),
            releaseElement(active, page, end)
          ])
        }
        return actionResult(active, page, "drag", { addressing: "elements" })
      }
      case "type":
        await fillElement(
          active,
          page,
          args.target,
          stringArgument(args, "text"),
          args.slowly === true
        )
        if (args.submit === true) await pressKey(active, page, "Enter")
        return actionResult(active, page, "type", { target: normalizeRef(args.target) })
      case "fill_form": {
        if (!Array.isArray(args.fields)) throw new Error("fields must be an array")
        for (const field of args.fields) {
          if (field === null || typeof field !== "object")
            throw new Error("Each field must be an object")
          const entry = field as Readonly<Record<string, unknown>>
          const target = entry.target ?? entry.ref
          const value = entry.value
          if (
            typeof value !== "string" &&
            typeof value !== "number" &&
            typeof value !== "boolean"
          ) {
            throw new Error("Each field value must be a string, number, or boolean")
          }
          await fillElement(active, page, target, String(value), false)
        }
        return verifiedActionResult(active, page, "fill_form", {
          fieldCount: args.fields.length
        })
      }
      case "select_option": {
        if (
          !Array.isArray(args.values) ||
          !args.values.every((value) => typeof value === "string")
        ) {
          throw new Error("values must be an array of strings")
        }
        const element = await resolveElement(active, page, args.target)
        let selected: string[]
        try {
          selected = await selectOptionsElement(active, page, element, args.values)
        } finally {
          await releaseElement(active, page, element)
        }
        return verifiedActionResult(active, page, "select_option", {
          target: normalizeRef(args.target),
          selected
        })
      }
      case "press_key":
        await pressKey(active, page, stringArgument(args, "key"))
        return actionResult(active, page, "press_key", { key: args.key })
      case "keyboard_type":
        await active.connection.send(
          "Input.insertText",
          { text: stringArgument(args, "text") },
          page.sessionId
        )
        return actionResult(active, page, "keyboard_type")
      case "wait": {
        if (typeof args.time === "number") await delay(Math.max(0, Math.min(30, args.time)) * 1_000)
        const expected = typeof args.text === "string" ? args.text : undefined
        const gone = typeof args.textGone === "string" ? args.textGone : undefined
        if (expected !== undefined || gone !== undefined) {
          const deadline = Date.now() + 30_000
          while (true) {
            const body = await evaluate<string>(active, page, "document.body?.innerText ?? ''")
            if (
              (expected === undefined || body.includes(expected)) &&
              (gone === undefined || !body.includes(gone))
            )
              break
            if (Date.now() >= deadline) throw new Error("Timed out waiting for page text")
            await delay(200)
          }
        }
        return pageResult(active, page, { action: "wait", path: "cdp", conditionMet: true })
      }
      case "dialog":
        await active.connection.send(
          "Page.handleJavaScriptDialog",
          {
            accept: args.accept === true,
            ...(typeof args.promptText === "string" ? { promptText: args.promptText } : {})
          },
          page.sessionId
        )
        return actionResult(active, page, "dialog")
      case "upload_files": {
        if (!Array.isArray(args.paths) || !args.paths.every((value) => typeof value === "string")) {
          throw new Error("paths must be an array of workspace file paths")
        }
        const snapshot = active.snapshots.get(page.target.targetId)
        const backendNodeId = snapshot?.targets.get(normalizeRef(args.target))
        if (backendNodeId === undefined)
          throw new Error("Unknown or stale file input target; re-snapshot")
        await active.connection.send(
          "DOM.setFileInputFiles",
          { files: args.paths, backendNodeId },
          page.sessionId
        )
        return actionResult(active, page, "upload_files", { fileCount: args.paths.length })
      }
      case "mouse_click": {
        const x = numberArgument(args, "x")
        const y = numberArgument(args, "y")
        await dispatchClick(
          active,
          page,
          x,
          y,
          String(args.button ?? "left"),
          args.doubleClick === true ? 2 : 1,
          mouseModifierMask(args.keypress)
        )
        return actionResult(active, page, "mouse_click", {
          addressing: "coordinate",
          x,
          y,
          doubleClick: args.doubleClick === true
        })
      }
      case "mouse_move": {
        const x = numberArgument(args, "x")
        const y = numberArgument(args, "y")
        await active.connection.send(
          "Input.dispatchMouseEvent",
          { type: "mouseMoved", x, y, modifiers: mouseModifierMask(args.keys) },
          page.sessionId
        )
        return actionResult(active, page, "mouse_move", { x, y })
      }
      case "mouse_drag": {
        const path = Array.isArray(args.path)
          ? args.path.map((point) => {
              if (point === null || typeof point !== "object" || Array.isArray(point)) {
                throw new Error("Each drag path point must be an object")
              }
              const candidate = point as Readonly<Record<string, unknown>>
              return { x: numberArgument(candidate, "x"), y: numberArgument(candidate, "y") }
            })
          : [
              { x: numberArgument(args, "startX"), y: numberArgument(args, "startY") },
              { x: numberArgument(args, "endX"), y: numberArgument(args, "endY") }
            ]
        if (path.length < 2) throw new Error("mouse_drag path must contain at least two points")
        const start = path[0]!
        const end = path.at(-1)!
        await active.connection.send(
          "Input.dispatchMouseEvent",
          {
            type: "mouseMoved",
            x: start.x,
            y: start.y,
            modifiers: mouseModifierMask(args.keys)
          },
          page.sessionId
        )
        await active.connection.send(
          "Input.dispatchMouseEvent",
          {
            type: "mousePressed",
            x: start.x,
            y: start.y,
            button: "left",
            buttons: 1,
            clickCount: 1,
            modifiers: mouseModifierMask(args.keys)
          },
          page.sessionId
        )
        for (const point of path.slice(1)) {
          await active.connection.send(
            "Input.dispatchMouseEvent",
            {
              type: "mouseMoved",
              x: point.x,
              y: point.y,
              button: "left",
              buttons: 1,
              modifiers: mouseModifierMask(args.keys)
            },
            page.sessionId
          )
        }
        await active.connection.send(
          "Input.dispatchMouseEvent",
          {
            type: "mouseReleased",
            x: end.x,
            y: end.y,
            button: "left",
            buttons: 0,
            clickCount: 1,
            modifiers: mouseModifierMask(args.keys)
          },
          page.sessionId
        )
        return actionResult(active, page, "mouse_drag", { pathLength: path.length })
      }
      case "mouse_scroll":
        await active.connection.send(
          "Input.dispatchMouseEvent",
          {
            type: "mouseWheel",
            x: typeof args.x === "number" ? args.x : 0,
            y: typeof args.y === "number" ? args.y : 0,
            deltaX: typeof args.deltaX === "number" ? args.deltaX : 0,
            deltaY: numberArgument(args, "deltaY"),
            modifiers: mouseModifierMask(args.keypress)
          },
          page.sessionId
        )
        return actionResult(active, page, "mouse_scroll")
      case "mouse_download_media": {
        const objectId = await mediaElementAtPoint(
          active,
          page,
          numberArgument(args, "x"),
          numberArgument(args, "y")
        )
        try {
          await triggerMediaDownload(active, page, objectId)
        } finally {
          await active.connection
            .send("Runtime.releaseObject", { objectId }, page.sessionId)
            .catch(() => undefined)
        }
        return actionResult(active, page, "mouse_download_media")
      }
      case "dom_download_media": {
        const element = await resolveElement(active, page, args.target, false)
        try {
          await triggerMediaDownload(active, page, element.objectId)
        } finally {
          await releaseElement(active, page, element)
        }
        return actionResult(active, page, "dom_download_media")
      }
      case "dom_scroll": {
        if (typeof args.target === "string") {
          const element = await resolveElement(active, page, args.target, false)
          try {
            await active.connection.send(
              "Runtime.callFunctionOn",
              {
                objectId: element.objectId,
                functionDeclaration: "function(x,y){this.scrollBy(x,y);}",
                arguments: [
                  { value: numberArgument(args, "x") },
                  { value: numberArgument(args, "y") }
                ],
                returnByValue: true
              },
              page.sessionId
            )
          } finally {
            await releaseElement(active, page, element)
          }
        } else {
          await active.connection.send(
            "Input.dispatchMouseEvent",
            {
              type: "mouseWheel",
              x: 0,
              y: 0,
              deltaX: numberArgument(args, "x"),
              deltaY: numberArgument(args, "y")
            },
            page.sessionId
          )
        }
        return actionResult(active, page, "dom_scroll")
      }
      default:
        throw new Error(`Unknown Browser Use tool: ${toolName}`)
    }
  }
}
