import type { BrowserRuntime, PageHandle } from "./browser-cdp-engine.js"
import { delay } from "./browser-cdp.js"
import type { BrowserCursor } from "./browser-cursor.js"

interface Point {
  readonly x: number
  readonly y: number
}

const dragSteps = 10
const dragStepMs = 16

export const dragBetween = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  cursor: BrowserCursor,
  start: Point,
  end: Point
): Promise<void> => {
  const mouse = (params: Readonly<Record<string, unknown>>) =>
    runtime.connection.send("Input.dispatchMouseEvent", params, page.sessionId)

  await cursor.move(start.x, start.y)
  await mouse({ type: "mouseMoved", x: start.x, y: start.y })
  await mouse({ type: "mousePressed", ...start, button: "left", buttons: 1, clickCount: 1 })
  for (let step = 1; step <= dragSteps; step++) {
    const progress = step / dragSteps
    const x = start.x + (end.x - start.x) * progress
    const y = start.y + (end.y - start.y) * progress
    await cursor.track(x, y)
    await mouse({ type: "mouseMoved", x, y, button: "left", buttons: 1 })
    await delay(dragStepMs)
  }
  await mouse({ type: "mouseReleased", ...end, button: "left", buttons: 0, clickCount: 1 })
  await cursor.pulse(end.x, end.y)
}
