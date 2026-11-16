import type { CallToolResult } from "@modelcontextprotocol/server"

import {
  jsonResult,
  openDialog,
  pageInformation,
  pageResult,
  stringArgument,
  waitForReady,
  type BrowserRuntime,
  type PageHandle,
  type ResolvedElement
} from "./browser-cdp-engine.js"
import { sendUnlessDialogOpens } from "./browser-dialog-race.js"
import { releaseElement, resolveElement } from "./browser-locators.js"
import {
  captureScreenshot,
  elementClip,
  fullPageClip,
  requestedClip,
  screenshotFormat,
  viewportClip,
  type ScreenshotClip
} from "./browser-screenshot.js"
import { grantSiteAccess, navigationFailure } from "./browser-site-access.js"
import { snapshotPage } from "./browser-snapshot.js"
import type { BrowserToolInvocation, BrowserToolSessionState } from "./browser-use-invoke-types.js"
import { maxWaitMs, waitBudget } from "./browser-wait-budget.js"

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
      await grantSiteAccess(active, page, url, args)
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
      if (sent.result.errorText !== undefined)
        throw navigationFailure(active, page, url, sent.result.errorText)
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
      return snapshotPage(active, page, {
        depth: Math.max(1, Math.min(60, Number(args.depth ?? 30))),
        root: args.root,
        offset: args.offset
      })
    case "screenshot": {
      let element: ResolvedElement | undefined
      if (args.clip === undefined && args.target !== undefined)
        element = await resolveElement(active, page, args.target, false)
      try {
        return await captureScreenshot(active, page, {
          format: screenshotFormat(args.type),
          clip: await screenshotClip(active, page, args, element),
          fullPage: args.fullPage === true
        })
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

const screenshotClip = (
  runtime: BrowserRuntime,
  page: PageHandle,
  args: Readonly<Record<string, unknown>>,
  element: ResolvedElement | undefined
): ScreenshotClip | Promise<ScreenshotClip> => {
  if (args.clip !== undefined) return requestedClip(args.clip)
  if (element !== undefined) return elementClip(runtime, page, element)
  if (args.fullPage === true) return fullPageClip(runtime, page)
  return viewportClip(runtime, page)
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
