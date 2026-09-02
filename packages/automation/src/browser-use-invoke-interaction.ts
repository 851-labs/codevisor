import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"
import { delay } from "./browser-cdp.js"
import {
  actionResult,
  evaluate,
  numberArgument,
  pageResult,
  stringArgument,
  verifiedActionResult
} from "./browser-cdp-engine.js"
import {
  dispatchClick,
  fillElement,
  mediaElementAtPoint,
  mouseModifierMask,
  pressKey,
  selectOptionsElement,
  triggerMediaDownload
} from "./browser-input.js"
import { releaseElement, resolveElement } from "./browser-locators.js"
import { normalizeRef } from "./browser-snapshot.js"
import type { BrowserToolInvocation, BrowserToolSessionState } from "./browser-use-invoke-types.js"

/// Element and coordinate interactions: clicking, typing, forms, keys, mouse, and media downloads.
/// Returns undefined for tool names this family does not own.
export const invokeInteractionTools = async (
  invocation: BrowserToolInvocation,
  _state: BrowserToolSessionState
): Promise<CallToolResult | undefined> => {
  const { active, args, page, toolName } = invocation
  switch (toolName) {
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
        await Promise.all([releaseElement(active, page, start), releaseElement(active, page, end)])
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
        if (typeof value !== "string" && typeof value !== "number" && typeof value !== "boolean") {
          throw new Error("Each field value must be a string, number, or boolean")
        }
        await fillElement(active, page, target, String(value), false)
      }
      return verifiedActionResult(active, page, "fill_form", {
        fieldCount: args.fields.length
      })
    }
    case "select_option": {
      if (!Array.isArray(args.values) || !args.values.every((value) => typeof value === "string")) {
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
      return undefined
  }
}
