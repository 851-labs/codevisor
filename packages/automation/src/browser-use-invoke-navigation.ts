import type { CallToolResult } from "@modelcontextprotocol/server"

import {
  jsonResult,
  numberArgument,
  openDialog,
  pageInformation,
  pageResult,
  stringArgument,
  waitForReady,
  type BrowserRuntime,
  type PageHandle,
  type ResolvedElement
} from "./browser-cdp-engine.js"
import { withoutPointerOverlay } from "./browser-cursor.js"
import { sendUnlessDialogOpens } from "./browser-dialog-race.js"
import { releaseElement, resolveElement } from "./browser-locators.js"
import { snapshotPage } from "./browser-snapshot.js"
import type { BrowserToolInvocation, BrowserToolSessionState } from "./browser-use-invoke-types.js"
import { maxWaitMs, waitBudget } from "./browser-wait-budget.js"
import { isPlainRecord } from "./unknown-values.js"

export const invokeNavigationTools = async (
  invocation: BrowserToolInvocation,
  _state: BrowserToolSessionState
): Promise<CallToolResult | undefined> => {
  const { active, args, page, toolName } = invocation
  switch (toolName) {
    case "tab_info": {
      const info = await tabInformation(active, page)
      return jsonResult({ id: page.target.targetId, ...info })
    }
    case "navigate": {
      const url = stringArgument(args, "url")
      const budget = waitBudget(args.timeoutMs)
      const sent = await sendUnlessDialogOpens<{ errorText?: string }>(
        active,
        page,
        "Page.navigate",
        { url },
        budget
      ).catch((cause: unknown) => {
        throw slowNavigation(cause, budget)
      })
      if (sent.dialogOpened) return navigationResult(active, page, "navigate")
      if (sent.result.errorText !== undefined) throw new Error(sent.result.errorText)
      await waitForReady(active, page)
      return navigationResult(active, page, "navigate")
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
      const sent = await sendUnlessDialogOpens(active, page, "Page.navigateToHistoryEntry", {
        entryId: entry.id
      })
      if (!sent.dialogOpened) await waitForReady(active, page)
      return navigationResult(active, page, toolName)
    }
    case "reload": {
      const sent = await sendUnlessDialogOpens(active, page, "Page.reload", {})
      if (!sent.dialogOpened) await waitForReady(active, page)
      return navigationResult(active, page, "reload")
    }
    case "snapshot":
      return snapshotPage(active, page, Math.max(1, Math.min(60, Number(args.depth ?? 30))))
    case "screenshot": {
      const format = args.type === "jpeg" ? "jpeg" : "png"
      let clip: { x: number; y: number; width: number; height: number; scale: number } | undefined
      let element: ResolvedElement | undefined
      if (args.clip !== undefined) {
        const requested = args.clip
        if (!isPlainRecord(requested)) throw new Error("clip must be an object")
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
        const captured = await withoutPointerOverlay(active, page, () =>
          active.connection.send<{ data: string }>(
            "Page.captureScreenshot",
            {
              format,
              fromSurface: true,
              captureBeyondViewport: args.fullPage === true,
              clip
            },
            page.sessionId
          )
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
    default:
      return undefined
  }
}

const slowNavigation = (cause: unknown, budget: number): unknown => {
  if (!/Browser command timed out: Page\.navigate/.test(String(cause))) return cause
  return new Error(
    `The page did not answer within ${budget} ms. Pass a larger timeoutMs to goto (up to ${maxWaitMs}).`
  )
}

const navigationResult = (runtime: BrowserRuntime, page: PageHandle, action: string) =>
  pageResult(runtime, page, { action, path: "cdp", delivered: true })

const tabInformation = async (
  runtime: BrowserRuntime,
  page: PageHandle
): Promise<{ url: string; title: string }> => {
  if (openDialog(runtime, page) !== undefined)
    return { url: page.target.url, title: page.target.title }
  return pageInformation(runtime, page)
}
