import type { BrowserRuntime, PageHandle } from "./browser-cdp-engine.js"
import { tabSessionOf } from "./browser-frame-sessions.js"

export interface FrameOffset {
  readonly x: number
  readonly y: number
}

export const tabPageOf = (runtime: BrowserRuntime, page: PageHandle): PageHandle => ({
  ...page,
  sessionId: tabSessionOf(runtime, page.sessionId)
})

export const frameOffsetInTab = async (
  runtime: BrowserRuntime,
  sessionId: string
): Promise<FrameOffset> => {
  const parentSessionId = runtime.frameParents.get(sessionId)
  const frameId = frameIdOfSession(runtime, sessionId)
  if (parentSessionId === undefined || frameId === undefined) return { x: 0, y: 0 }

  const owner = await runtime.connection.send<{ backendNodeId: number }>(
    "DOM.getFrameOwner",
    { frameId },
    parentSessionId
  )
  const box = await runtime.connection.send<{ model: { content: number[] } }>(
    "DOM.getBoxModel",
    { backendNodeId: owner.backendNodeId },
    parentSessionId
  )
  const outer = await frameOffsetInTab(runtime, parentSessionId)
  return { x: outer.x + (box.model.content[0] ?? 0), y: outer.y + (box.model.content[1] ?? 0) }
}

const frameIdOfSession = (runtime: BrowserRuntime, sessionId: string): string | undefined =>
  [...runtime.sessions].find(([, candidate]) => candidate === sessionId)?.[0]
