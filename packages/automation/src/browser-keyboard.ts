import type { BrowserRuntime, PageHandle } from "./browser-cdp-engine.js"
import { browserHostIsMac, macEditingCommands } from "./browser-key-commands.js"
import { browserKeyDescription } from "./browser-key-description.js"

export { browserKeyDescription } from "./browser-key-description.js"

export const modifierKeyMask = (key: string): number => {
  switch (key) {
    case "Alt":
      return 1
    case "Control":
      return 2
    case "Meta":
      return 4
    case "Shift":
      return 8
    default:
      return 0
  }
}

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

const keyEventParameters = (
  type: "keyDown" | "keyUp",
  rest: Omit<ReturnType<typeof browserKeyDescription>, "text">,
  text: string | undefined
): Record<string, unknown> => {
  if (type === "keyUp") return { type: "keyUp", ...rest }
  if (text === undefined) return { type: "rawKeyDown", ...rest }
  return { type: "keyDown", ...rest, text }
}

const editingCommands = (
  runtime: BrowserRuntime,
  key: ReturnType<typeof browserKeyDescription>,
  type: "keyDown" | "keyUp"
): { commands?: string[] } => {
  if (type === "keyUp" || !browserHostIsMac(runtime.native)) return {}
  const commands = macEditingCommands(key)
  return commands.length === 0 ? {} : { commands }
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
    { ...keyEventParameters(type, rest, text), ...editingCommands(runtime, key, type) },
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
