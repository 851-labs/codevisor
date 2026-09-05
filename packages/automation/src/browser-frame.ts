import { attachTarget, type BrowserRuntime, type PageHandle } from "./browser-cdp-engine.js"
import { locatorBackendNodeIds } from "./browser-locator-resolve.js"

/** Chrome isolates cross-site frames in child debugger sessions. Never resolve their nodes in the parent. */
export const routeBrowserFrame = async (
  runtime: BrowserRuntime,
  original: PageHandle,
  value: unknown
): Promise<{ page: PageHandle; locator: unknown }> => {
  if (!value || typeof value !== "object" || !("frame" in value) || !Array.isArray(value.frame))
    return { page: original, locator: value }
  let page = original
  let frame: string[] = []
  for (const selector of value.frame) {
    if (typeof selector !== "string") throw new Error("Frame selector must be a string")
    const ids = await locatorBackendNodeIds(runtime, page, { css: selector, frame })
    if (ids.length !== 1)
      throw new Error(`frameLocator(${JSON.stringify(selector)}) resolved to ${ids.length} frames`)
    const { node } = await runtime.connection.send<{
      node: { contentDocument?: { backendNodeId?: number }; frameId?: string }
    }>("DOM.describeNode", { backendNodeId: ids[0], depth: 1, pierce: true }, page.sessionId)
    if (node.contentDocument?.backendNodeId !== undefined) {
      frame.push(selector)
      continue
    }
    if (!node.frameId) throw new Error("The frame document is not available")
    const sessionId = await attachTarget(runtime, node.frameId, page.sessionId)
    page = { ...page, sessionId }
    frame = []
  }
  return { page, locator: { ...value, frame } }
}
