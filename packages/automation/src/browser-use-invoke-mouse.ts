import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"
import { actionResult, numberArgument } from "./browser-cdp-engine.js"
import {
  dispatchClick,
  dispatchMouseEvent,
  heldButtonName,
  mediaElementAtPoint,
  mouseButtonMask,
  mouseButtonName,
  mouseModifierMask,
  triggerMediaDownload
} from "./browser-input.js"
import { releaseElement, resolveElement } from "./browser-locators.js"
import type { BrowserToolInvocation, BrowserToolSessionState } from "./browser-use-invoke-types.js"

/// Coordinate mouse input and DOM scrolling and media downloads. The session's pointer state
/// makes mouse_down, mouse_move, and mouse_up compose into drags like Playwright's Mouse, and
/// every move animates the presented cursor first. Returns undefined for other tool names.
export const invokeMouseTools = async (
  invocation: BrowserToolInvocation,
  _state: BrowserToolSessionState
): Promise<CallToolResult | undefined> => {
  const { active, args, cursor, page, pointer, toolName } = invocation
  switch (toolName) {
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
        mouseModifierMask(args.keypress),
        cursor
      )
      Object.assign(pointer, { x, y })
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
      const modifiers = mouseModifierMask(args.keys) | pointer.modifiers
      const steps =
        typeof args.steps === "number" && Number.isFinite(args.steps)
          ? Math.max(1, Math.min(200, Math.floor(args.steps)))
          : 1
      const held = heldButtonName(pointer.buttons)
      const from = { x: pointer.x, y: pointer.y }
      // Free moves animate the presented pointer first; a held button follows each step so the
      // drag reads as one continuous gesture.
      if (held === undefined) await cursor.move(x, y)
      for (let step = 1; step <= steps; step++) {
        const stepX = from.x + ((x - from.x) * step) / steps
        const stepY = from.y + ((y - from.y) * step) / steps
        if (held !== undefined) await cursor.track(stepX, stepY)
        const moved = await dispatchMouseEvent(active, page, {
          type: "mouseMoved",
          x: stepX,
          y: stepY,
          modifiers,
          buttons: pointer.buttons,
          ...(held === undefined ? {} : { button: held })
        })
        pointer.x = stepX
        pointer.y = stepY
        if (moved.dialogOpened) break
      }
      return actionResult(active, page, "mouse_move", {
        x,
        y,
        steps,
        ...(held === undefined ? {} : { dragging: held })
      })
    }
    case "mouse_down":
    case "mouse_up": {
      const x = typeof args.x === "number" ? args.x : pointer.x
      const y = typeof args.y === "number" ? args.y : pointer.y
      const button = mouseButtonName(args.button)
      const mask = mouseButtonMask(button)
      const clickCount =
        typeof args.clickCount === "number" ? Math.max(1, Math.floor(args.clickCount)) : 1
      const modifiers = mouseModifierMask(args.keys) | pointer.modifiers
      if (x !== pointer.x || y !== pointer.y) {
        if (pointer.buttons === 0) await cursor.move(x, y)
        else await cursor.track(x, y)
        const moved = await dispatchMouseEvent(active, page, {
          type: "mouseMoved",
          x,
          y,
          modifiers,
          buttons: pointer.buttons,
          ...(heldButtonName(pointer.buttons) === undefined
            ? {}
            : { button: heldButtonName(pointer.buttons) })
        })
        pointer.x = x
        pointer.y = y
        if (moved.dialogOpened) return actionResult(active, page, toolName, { x, y, button })
      }
      if (toolName === "mouse_down") {
        pointer.buttons |= mask
        await dispatchMouseEvent(active, page, {
          type: "mousePressed",
          x,
          y,
          button,
          buttons: pointer.buttons,
          clickCount,
          modifiers
        })
      } else {
        pointer.buttons &= ~mask
        await dispatchMouseEvent(active, page, {
          type: "mouseReleased",
          x,
          y,
          button,
          buttons: pointer.buttons,
          clickCount,
          modifiers
        })
        await cursor.pulse(x, y)
      }
      return actionResult(active, page, toolName, { x, y, button, clickCount })
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
      await cursor.move(start.x, start.y)
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
        await cursor.track(point.x, point.y)
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
      await cursor.pulse(end.x, end.y)
      Object.assign(pointer, { x: end.x, y: end.y })
      return actionResult(active, page, "mouse_drag", { pathLength: path.length })
    }
    case "mouse_scroll": {
      const x = typeof args.x === "number" ? args.x : pointer.x
      const y = typeof args.y === "number" ? args.y : pointer.y
      if (x !== pointer.x || y !== pointer.y) await cursor.move(x, y)
      await active.connection.send(
        "Input.dispatchMouseEvent",
        {
          type: "mouseWheel",
          x,
          y,
          deltaX: typeof args.deltaX === "number" ? args.deltaX : 0,
          deltaY: numberArgument(args, "deltaY"),
          modifiers: mouseModifierMask(args.keypress) | pointer.modifiers
        },
        page.sessionId
      )
      pointer.x = x
      pointer.y = y
      return actionResult(active, page, "mouse_scroll", { x, y })
    }
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
      return undefined
  }
}
