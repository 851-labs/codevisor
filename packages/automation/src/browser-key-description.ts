export const browserKeyDescription = (
  value: string
): {
  key: string
  code: string
  windowsVirtualKeyCode: number
  modifiers: number
  text?: string
} => {
  const parts = chordParts(value)
  if (parts.length === 0) throw new Error("key is required")
  const modifiers = chordModifiers(parts)
  const raw = parts.at(-1)!
  const match = namedKeyDescription(raw, modifiers)
  if (match !== undefined) return match
  return printableKeyDescription(raw, modifiers)
}

const chordParts = (value: string): string[] => {
  return [...value].length === 1
    ? [value === " " ? "Space" : value]
    : value
        .split("+")
        .map((part) => part.trim())
        .filter(Boolean)
}

const chordModifiers = (parts: string[]): number => {
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
  return modifiers
}

const namedKeyDescription = (
  raw: string,
  modifiers: number
): ReturnType<typeof browserKeyDescription> | undefined => {
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
  return undefined
}

const printableKeyDescription = (
  raw: string,
  modifiers: number
): ReturnType<typeof browserKeyDescription> => {
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
