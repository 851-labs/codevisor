import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"
import {
  jsonResult,
  numberArgument,
  pageInformation,
  pageResult,
  stringArgument,
  waitForReady
} from "./browser-cdp-engine.js"
import type { ResolvedElement } from "./browser-cdp-engine.js"
import { releaseElement, resolveElement } from "./browser-locators.js"
import { snapshotPage } from "./browser-snapshot.js"
import type { BrowserToolInvocation, BrowserToolSessionState } from "./browser-use-invoke-types.js"

/// Tab information, navigation, and page capture (snapshot/screenshot).
/// Returns undefined for tool names this family does not own.
export const invokeNavigationTools = async (
  invocation: BrowserToolInvocation,
  _state: BrowserToolSessionState
): Promise<CallToolResult | undefined> => {
  const { active, args, page, toolName } = invocation
  switch (toolName) {
    case "tab_info": {
      const info = await pageInformation(active, page)
      return jsonResult({ id: page.target.targetId, ...info })
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
    default:
      return undefined
  }
}
