import type { BrowserRuntime, PageHandle } from "./browser-cdp-engine.js"

/**
 * Trusted keyboard input for Browser Use, shaped after Playwright's `Keyboard`: chords parse to
 * CDP key descriptions, keydown and keyup dispatch separately, and modifiers held through
 * key_down apply to later presses.
 */

export const browserKeyDescription = (
  value: string
): {
  key: string
  code: string
  windowsVirtualKeyCode: number
  modifiers: number
  text?: string
} => {
  const parts =
    [...value].length === 1
      ? [value === " " ? "Space" : value]
      : value
          .split("+")
          .map((part) => part.trim())
          .filter(Boolean)
  if (parts.length === 0) throw new Error("key is required")
  let modifiers = 0
  for (const modifier of parts.slice(0, -1)) {
    switch (modifier.toLowerCase()) {
      case "alt":
      case "option":
        modifiers |= 1
        break
      case "ctrl":
      case "control":
        modifiers |= 2
        break
      case "controlormeta":
        modifiers |= process.platform === "darwin" ? 4 : 2
        break
      case "meta":
      case "cmd":
      case "command":
        modifiers |= 4
        break
      case "shift":
        modifiers |= 8
        break
      default:
        throw new Error(`Unsupported key modifier: ${modifier}`)
    }
  }
  const raw = parts.at(-1)!
  const named: Readonly<Record<string, [string, string, number]>> = {
    enter: ["Enter", "Enter", 13],
    return: ["Enter", "Enter", 13],
    tab: ["Tab", "Tab", 9],
    escape: ["Escape", "Escape", 27],
    esc: ["Escape", "Escape", 27],
    backspace: ["Backspace", "Backspace", 8],
    delete: ["Delete", "Delete", 46],
    space: [" ", "Space", 32],
    spacebar: [" ", "Space", 32],
    left: ["ArrowLeft", "ArrowLeft", 37],
    arrowleft: ["ArrowLeft", "ArrowLeft", 37],
    right: ["ArrowRight", "ArrowRight", 39],
    arrowright: ["ArrowRight", "ArrowRight", 39],
    up: ["ArrowUp", "ArrowUp", 38],
    arrowup: ["ArrowUp", "ArrowUp", 38],
    down: ["ArrowDown", "ArrowDown", 40],
    arrowdown: ["ArrowDown", "ArrowDown", 40],
    home: ["Home", "Home", 36],
    end: ["End", "End", 35],
    pageup: ["PageUp", "PageUp", 33],
    pagedown: ["PageDown", "PageDown", 34],
    shift: ["Shift", "ShiftLeft", 16],
    control: ["Control", "ControlLeft", 17],
    ctrl: ["Control", "ControlLeft", 17],
    alt: ["Alt", "AltLeft", 18],
    option: ["Alt", "AltLeft", 18],
    meta: ["Meta", "MetaLeft", 91],
    cmd: ["Meta", "MetaLeft", 91],
    command: ["Meta", "MetaLeft", 91],
    insert: ["Insert", "Insert", 45],
    capslock: ["CapsLock", "CapsLock", 20],
    ...Object.fromEntries(
      Array.from({ length: 12 }, (_, index) => [
        `f${index + 1}`,
        [`F${index + 1}`, `F${index + 1}`, 112 + index]
      ])
    )
  }
  const match = named[raw.toLowerCase()]
  if (match !== undefined) {
    const text = match[0] === "Enter" ? "\r" : match[0] === " " ? " " : undefined
    return {
      key: match[0],
      code: match[1],
      windowsVirtualKeyCode: match[2],
      modifiers,
      ...(text !== undefined && (modifiers & (2 | 4)) === 0 ? { text } : {})
    }
  }
  if ([...raw].length !== 1) throw new Error(`Unsupported key: ${raw}`)
  const upper = raw.toUpperCase()
  const letter = /^[A-Z]$/.test(upper)
  const code = letter ? `Key${upper}` : /^[0-9]$/.test(raw) ? `Digit${raw}` : raw
  const key = (modifiers & 8) !== 0 ? upper : raw
  return {
    key,
    code,
    windowsVirtualKeyCode: upper.codePointAt(0)!,
    modifiers,
    ...((modifiers & (2 | 4)) === 0 ? { text: key } : {})
  }
}

/** The modifier bit a standalone modifier key contributes while held, or 0 for other keys. */
export const modifierKeyMask = (key: string): number =>
  key === "Alt" ? 1 : key === "Control" ? 2 : key === "Meta" ? 4 : key === "Shift" ? 8 : 0

/**
 * Describe a key press while `heldModifiers` are down, like Playwright's `Keyboard` does: the
 * held mask is merged in and a single letter reports its shifted form.
 */
export const heldKeyDescription = (
  value: string,
  heldModifiers: number
): ReturnType<typeof browserKeyDescription> => {
  const key = browserKeyDescription(value)
  const modifiers = key.modifiers | heldModifiers
  if (modifiers === key.modifiers) return key
  const shifted =
    (modifiers & 8) !== 0 && /^[a-z]$/i.test(key.key) ? key.key.toUpperCase() : key.key
  // Control or Meta turn a printable key into a shortcut: no character is inserted.
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
