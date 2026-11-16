import type { CallToolResult } from "@modelcontextprotocol/server"

import {
  numberArgument,
  pageInformation,
  type BrowserRuntime,
  type PageHandle,
  type ResolvedElement
} from "./browser-cdp-engine.js"
import { withoutPointerOverlay } from "./browser-cursor.js"
import { isPlainRecord } from "./unknown-values.js"

export interface ScreenshotClip {
  readonly x: number
  readonly y: number
  readonly width: number
  readonly height: number
  readonly scale: 1
}

export interface ScreenshotRequest {
  readonly format: "png" | "jpeg"
  readonly clip: ScreenshotClip
  readonly fullPage: boolean
}

export const screenshotFormat = (type: unknown): "png" | "jpeg" =>
  type === "jpeg" ? "jpeg" : "png"

export const captureScreenshot = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  request: ScreenshotRequest
): Promise<CallToolResult> => {
  const captured = await withoutPointerOverlay(runtime, page, () =>
    runtime.connection
      .send<{ data: string }>(
        "Page.captureScreenshot",
        {
          format: request.format,
          fromSurface: true,
          captureBeyondViewport: request.fullPage,
          clip: request.clip
        },
        page.sessionId
      )
      .catch((cause: unknown) => {
        throw captureFailure(cause, request)
      })
  )
  const info = await pageInformation(runtime, page)
  return {
    content: [
      {
        type: "text",
        text: `Page URL: ${info.url}\nScreenshot coordinates are CSS viewport coordinates.`
      },
      { type: "image", data: captured.data, mimeType: `image/${request.format}` }
    ]
  }
}

export const requestedClip = (requested: unknown): ScreenshotClip => {
  if (!isPlainRecord(requested)) throw new Error("clip must be an object")
  return {
    x: numberArgument(requested, "x"),
    y: numberArgument(requested, "y"),
    width: numberArgument(requested, "width"),
    height: numberArgument(requested, "height"),
    scale: 1
  }
}

export const elementClip = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  element: ResolvedElement
): Promise<ScreenshotClip> => {
  const viewport = await visualViewport(runtime, page)
  return {
    x: viewport.pageX + element.x - element.width / 2,
    y: viewport.pageY + element.y - element.height / 2,
    width: element.width,
    height: element.height,
    scale: 1
  }
}

export const fullPageClip = async (
  runtime: BrowserRuntime,
  page: PageHandle
): Promise<ScreenshotClip> => {
  const metrics = await runtime.connection.send<{
    contentSize: { x: number; y: number; width: number; height: number }
  }>("Page.getLayoutMetrics", {}, page.sessionId)
  return { ...metrics.contentSize, scale: 1 }
}

export const viewportClip = async (
  runtime: BrowserRuntime,
  page: PageHandle
): Promise<ScreenshotClip> => {
  const viewport = await visualViewport(runtime, page)
  return {
    x: viewport.pageX,
    y: viewport.pageY,
    width: viewport.clientWidth,
    height: viewport.clientHeight,
    scale: 1
  }
}

interface VisualViewport {
  readonly pageX: number
  readonly pageY: number
  readonly clientWidth: number
  readonly clientHeight: number
}

const visualViewport = async (runtime: BrowserRuntime, page: PageHandle): Promise<VisualViewport> =>
  (
    await runtime.connection.send<{ cssVisualViewport: VisualViewport }>(
      "Page.getLayoutMetrics",
      {},
      page.sessionId
    )
  ).cssVisualViewport

const captureFailure = (cause: unknown, request: ScreenshotRequest): unknown => {
  if (!request.fullPage) return cause
  const { width, height } = request.clip
  return new Error(
    `The whole page is ${Math.round(width)} x ${Math.round(height)} px, too large for the browser to capture as one image. Capture it in parts with tab.screenshot({ clip: { x, y, width, height } }), or read it with tab.getAXState().`
  )
}
