import type { BrowserRuntime, PageHandle } from "./browser-cdp-engine.js"
import { browserKeyDescription } from "./browser-key-description.js"

export { browserKeyDescription } from "./browser-key-description.js"

export const modifierKeyMask = (key: string): number =>
  key === "Alt" ? 1 : key === "Control" ? 2 : key === "Meta" ? 4 : key === "Shift" ? 8 : 0

export const heldKeyDescription = (
  value: string,
  heldModifiers: number
): ReturnType<typeof browserKeyDescription> => {
  const key = browserKeyDescription(value)
  const modifiers = key.modifiers | heldModifiers
  if (modifiers === key.modifiers) return key
  const shifted =
    (modifiers & 8) !== 0 && /^[a-z]$/i.test(key.key) ? key.key.toUpperCase() : key.key
  const typed = (modifiers & (2 | 4)) === 0 && key.text !== undefined
  const { text: _text, ...base } = key
  return {
    ...base,
    key: shifted,
    modifiers,
    ...(typed ? { text: shifted === key.key ? key.text : shifted } : {})
  }
}

export const dispatchKeyEvent = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  key: ReturnType<typeof browserKeyDescription>,
  type: "keyDown" | "keyUp"
): Promise<void> => {
  const { text, ...rest } = key
  await runtime.connection.send(
    "Input.dispatchKeyEvent",
    type === "keyUp"
      ? { type: "keyUp", ...rest }
      : text === undefined
        ? { type: "rawKeyDown", ...rest }
        : { type: "keyDown", ...rest, text },
    page.sessionId
  )
}

export const pressKey = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  value: string,
  heldModifiers = 0
): Promise<void> => {
  const key = heldKeyDescription(value, heldModifiers)
  await dispatchKeyEvent(runtime, page, key, "keyDown")
  await dispatchKeyEvent(runtime, page, key, "keyUp")
}
