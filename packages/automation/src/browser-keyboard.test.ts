import { describe, expect, it } from "vitest"

import type { PageHandle } from "./browser-cdp-engine.js"
import {
  browserKeyDescription,
  dispatchKeyEvent,
  heldKeyDescription,
  modifierKeyMask,
  pressKey
} from "./browser-keyboard.js"
import { fakeBrowserRuntime, fakeCdpConnection } from "./browser-runtime-test-support.js"

const page: PageHandle = {
  target: { targetId: "tab", type: "page", title: "", url: "about:blank" },
  sessionId: "tab:1"
}

const fakeRuntime = () => {
  const sent: Array<Readonly<Record<string, unknown>>> = []
  const { connection } = fakeCdpConnection({
    send: async (_method, params) => {
      sent.push(params)
      return {}
    }
  })
  return { runtime: fakeBrowserRuntime({ connection }), sent }
}

describe("browser keyboard", () => {
  it("parses chords into CDP modifier masks", () => {
    expect(browserKeyDescription("Alt+a").modifiers).toBe(1)
    expect(browserKeyDescription("Option+a").modifiers).toBe(1)
    expect(browserKeyDescription("Ctrl+a").modifiers).toBe(2)
    expect(browserKeyDescription("Control+a").modifiers).toBe(2)
    expect(browserKeyDescription("Meta+a").modifiers).toBe(4)
    expect(browserKeyDescription("Cmd+a").modifiers).toBe(4)
    expect(browserKeyDescription("Command+a").modifiers).toBe(4)
    const platform = Object.getOwnPropertyDescriptor(process, "platform")!
    try {
      Object.defineProperty(process, "platform", { value: "darwin", configurable: true })
      expect(browserKeyDescription("ControlOrMeta+a").modifiers).toBe(4)
      Object.defineProperty(process, "platform", { value: "linux", configurable: true })
      expect(browserKeyDescription("ControlOrMeta+a").modifiers).toBe(2)
    } finally {
      Object.defineProperty(process, "platform", platform)
    }
    expect(browserKeyDescription("Shift+a")).toMatchObject({ key: "A", modifiers: 8, text: "A" })
    expect(browserKeyDescription("Control+Shift+a")).toMatchObject({ key: "A", modifiers: 10 })
    expect(browserKeyDescription("Control+Shift+a")).not.toHaveProperty("text")
    expect(() => browserKeyDescription("Hyper+a")).toThrow("Unsupported key modifier: Hyper")
    expect(() => browserKeyDescription(" + ")).toThrow("key is required")
    expect(() => browserKeyDescription("Bogus")).toThrow("Unsupported key: Bogus")
  })

  it("describes letters, digits, symbols, modifier keys, and function keys", () => {
    expect(browserKeyDescription("r")).toMatchObject({ key: "r", code: "KeyR", text: "r" })
    expect(browserKeyDescription("7")).toMatchObject({ key: "7", code: "Digit7" })
    expect(browserKeyDescription("/")).toMatchObject({ key: "/", code: "/" })
    expect(browserKeyDescription("Shift")).toMatchObject({ key: "Shift", code: "ShiftLeft" })
    expect(browserKeyDescription("Meta")).toMatchObject({ key: "Meta", windowsVirtualKeyCode: 91 })
    expect(browserKeyDescription("F5")).toMatchObject({ key: "F5", windowsVirtualKeyCode: 116 })
    expect(browserKeyDescription("Enter")).toMatchObject({ text: "\r" })
    expect(browserKeyDescription("Space")).toMatchObject({ text: " " })
    expect(browserKeyDescription(" ")).toMatchObject({ text: " ", code: "Space" })
    expect(browserKeyDescription("+")).toMatchObject({ text: "+", key: "+" })
    expect(browserKeyDescription("Control+Enter")).not.toHaveProperty("text")
  })

  it("accepts Playwright and legacy names for navigation keys", () => {
    const arrowRight = { key: "ArrowRight", code: "ArrowRight", windowsVirtualKeyCode: 39 }
    expect(browserKeyDescription("ArrowRight")).toMatchObject(arrowRight)
    expect(browserKeyDescription("Right")).toMatchObject(arrowRight)
    expect(browserKeyDescription("Esc")).toMatchObject({ key: "Escape" })
  })

  it("applies modifiers held through key_down like Playwright's Keyboard", () => {
    expect(modifierKeyMask("Shift")).toBe(8)
    expect(modifierKeyMask("Control")).toBe(2)
    expect(modifierKeyMask("Alt")).toBe(1)
    expect(modifierKeyMask("Meta")).toBe(4)
    expect(modifierKeyMask("a")).toBe(0)
    const plain = heldKeyDescription("a", 0)
    expect(plain).toEqual(browserKeyDescription("a"))
    expect(heldKeyDescription("a", 8)).toMatchObject({ key: "A", modifiers: 8, text: "A" })
    expect(heldKeyDescription("a", 2)).not.toHaveProperty("text")
    expect(heldKeyDescription("Enter", 8)).toMatchObject({ key: "Enter", modifiers: 8, text: "\r" })
    expect(heldKeyDescription("a", 1)).toMatchObject({ text: "a", modifiers: 1 })
  })

  it("dispatches split key events with the right CDP shapes", async () => {
    const { runtime, sent } = fakeRuntime()
    await dispatchKeyEvent(runtime, page, browserKeyDescription("a"), "keyDown")
    await dispatchKeyEvent(runtime, page, browserKeyDescription("Control+a"), "keyDown")
    await dispatchKeyEvent(runtime, page, browserKeyDescription("a"), "keyUp")
    await pressKey(runtime, page, "b", 8)
    expect(sent.map((params) => [params.type, params.key, "text" in params])).toEqual([
      ["keyDown", "a", true],
      ["rawKeyDown", "a", false],
      ["keyUp", "a", false],
      ["keyDown", "B", true],
      ["keyUp", "B", false]
    ])
  })
})
