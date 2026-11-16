import { attachTarget, type BrowserRuntime, type PageHandle } from "./browser-cdp-engine.js"
import { type BrowserFrameStep, parseLocatorFrame } from "./browser-locator-parse.js"
import { frameElementIds } from "./browser-locator-resolve.js"

export const routeBrowserFrame = async (
  runtime: BrowserRuntime,
  original: PageHandle,
  value: unknown
): Promise<{ page: PageHandle; locator: unknown }> => {
  if (!value || typeof value !== "object" || !("frame" in value) || !Array.isArray(value.frame))
    return { page: original, locator: value }
  let page = original
  let frame: BrowserFrameStep[] = []
  for (const step of parseLocatorFrame(value.frame) ?? []) {
    const ids = await frameElementIds(runtime, page, frame, step)
    if (ids.length !== 1) throw new Error(ambiguousFrame(step, ids.length))
    const { node } = await runtime.connection.send<{
      node: { contentDocument?: { backendNodeId?: number }; frameId?: string }
    }>("DOM.describeNode", { backendNodeId: ids[0], depth: 1, pierce: true }, page.sessionId)
    if (node.contentDocument?.backendNodeId !== undefined) {
      frame.push(step)
      continue
    }
    if (!node.frameId) throw new Error("The frame document is not available")
    const sessionId = await attachTarget(runtime, node.frameId, page.sessionId)
    page = { ...original, sessionId }
    frame = []
  }
  return { page, locator: { ...value, frame } }
}

const ambiguousFrame = (step: BrowserFrameStep, matches: number): string => {
  const selector = `frameLocator(${JSON.stringify(step.css)})`
  if (matches === 0) return `${selector} resolved to 0 frames`
  return `${selector} resolved to ${matches} frames; pick one with .first(), .last() or .nth(index)`
}
