import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"
import { delay } from "./browser-cdp.js"
import {
  actionResult,
  evaluate,
  pageResult,
  stringArgument,
  verifiedActionResult
} from "./browser-cdp-engine.js"
import {
  dispatchClick,
  dispatchKeyEvent,
  fillElement,
  heldKeyDescription,
  modifierKeyMask,
  pressKey,
  selectOptionsElement
} from "./browser-input.js"
import { releaseElement, resolveElement } from "./browser-locators.js"
import { normalizeRef } from "./browser-snapshot.js"
import type { BrowserToolInvocation, BrowserToolSessionState } from "./browser-use-invoke-types.js"

/// Element and coordinate interactions: clicking, typing, forms, keys, mouse, and media downloads.
/// Every pointer action animates the session's presented cursor first and keeps the session's
/// pointer state current, so held buttons and modifiers compose like Playwright's Mouse and
/// Keyboard. Returns undefined for tool names this family does not own.
export const invokeInteractionTools = async (
  invocation: BrowserToolInvocation,
  _state: BrowserToolSessionState
): Promise<CallToolResult | undefined> => {
  const { active, args, cursor, page, pointer, toolName } = invocation
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
          args.doubleClick === true ? 2 : 1,
          0,
          cursor
        )
      } finally {
        await releaseElement(active, page, element)
      }
      Object.assign(pointer, { x: element.x, y: element.y })
      return actionResult(active, page, "click", {
        addressing: "element",
        target: normalizeRef(args.target)
      })
    }
    case "hover": {
      const element = await resolveElement(active, page, args.target, false)
      try {
        await cursor.move(element.x, element.y)
        await active.connection.send(
          "Input.dispatchMouseEvent",
          { type: "mouseMoved", x: element.x, y: element.y },
          page.sessionId
        )
      } finally {
        await releaseElement(active, page, element)
      }
      Object.assign(pointer, { x: element.x, y: element.y })
      return actionResult(active, page, "hover", { target: normalizeRef(args.target) })
    }
    case "drag": {
      const start = await resolveElement(active, page, args.startTarget)
      const end = await resolveElement(active, page, args.endTarget)
      try {
        await cursor.move(start.x, start.y)
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
          const x = start.x + (end.x - start.x) * progress
          const y = start.y + (end.y - start.y) * progress
          await cursor.track(x, y)
          await active.connection.send(
            "Input.dispatchMouseEvent",
            { type: "mouseMoved", x, y, button: "left", buttons: 1 },
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
        await cursor.pulse(end.x, end.y)
      } finally {
        await Promise.all([releaseElement(active, page, start), releaseElement(active, page, end)])
      }
      Object.assign(pointer, { x: end.x, y: end.y })
      return actionResult(active, page, "drag", { addressing: "elements" })
    }
    case "type":
      await fillElement(
        active,
        page,
        args.target,
        stringArgument(args, "text"),
        args.slowly === true,
        cursor
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
        await fillElement(active, page, target, String(value), false, cursor)
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
        await cursor.move(element.x, element.y)
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
      await pressKey(active, page, stringArgument(args, "key"), pointer.modifiers)
      return actionResult(active, page, "press_key", { key: args.key })
    case "key_down":
    case "key_up": {
      const key = heldKeyDescription(stringArgument(args, "key"), pointer.modifiers)
      const modifierBit = modifierKeyMask(key.key)
      if (toolName === "key_down") {
        // Like Playwright, a modifier key's own keydown already reports it as held.
        pointer.modifiers |= modifierBit
        await dispatchKeyEvent(
          active,
          page,
          { ...key, modifiers: key.modifiers | modifierBit },
          "keyDown"
        )
      } else {
        pointer.modifiers &= ~modifierBit
        await dispatchKeyEvent(
          active,
          page,
          { ...key, modifiers: key.modifiers & ~modifierBit },
          "keyUp"
        )
      }
      return actionResult(active, page, toolName, { key: key.key })
    }
    case "keyboard_type": {
      const text = stringArgument(args, "text")
      if (args.mode === "keys") {
        // Playwright's keyboard.type: a key event per character, so shortcuts fire.
        for (const character of text) {
          await pressKey(active, page, character, pointer.modifiers)
        }
      } else {
        await active.connection.send("Input.insertText", { text }, page.sessionId)
      }
      return actionResult(active, page, "keyboard_type", {
        mode: args.mode === "keys" ? "keys" : "insert"
      })
    }
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
      const snapshot = active.snapshots.get(page.snapshotKey ?? page.target.targetId)
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
    default:
      return undefined
  }
}
