// Maps a resolved pierre/shiki theme onto xterm's ITheme: terminal/editor
// surfaces plus the 16 ANSI slots VS Code themes carry.
import type { ThemeLike } from "@pierre/theming"
import { normalizeThemeColors } from "@pierre/theming/color"
import type { ITheme } from "@xterm/xterm"

const ANSI_KEYS = [
  ["black", "terminal.ansiBlack"],
  ["red", "terminal.ansiRed"],
  ["green", "terminal.ansiGreen"],
  ["yellow", "terminal.ansiYellow"],
  ["blue", "terminal.ansiBlue"],
  ["magenta", "terminal.ansiMagenta"],
  ["cyan", "terminal.ansiCyan"],
  ["white", "terminal.ansiWhite"],
  ["brightBlack", "terminal.ansiBrightBlack"],
  ["brightRed", "terminal.ansiBrightRed"],
  ["brightGreen", "terminal.ansiBrightGreen"],
  ["brightYellow", "terminal.ansiBrightYellow"],
  ["brightBlue", "terminal.ansiBrightBlue"],
  ["brightMagenta", "terminal.ansiBrightMagenta"],
  ["brightCyan", "terminal.ansiBrightCyan"],
  ["brightWhite", "terminal.ansiBrightWhite"]
] as const

export function xtermThemeFrom(theme: ThemeLike | undefined): ITheme {
  if (theme == null) return {}
  const raw = theme.colors ?? {}
  const resolved = normalizeThemeColors(theme).colors ?? {}
  const background =
    raw["terminal.background"] ?? resolved["editor.background"] ?? theme.bg ?? undefined
  const foreground =
    raw["terminal.foreground"] ?? resolved["editor.foreground"] ?? theme.fg ?? undefined
  const result: ITheme = {
    background,
    foreground,
    cursor: raw["terminalCursor.foreground"] ?? foreground,
    selectionBackground: raw["terminal.selectionBackground"] ?? raw["editor.selectionBackground"]
  }
  for (const [xtermKey, themeKey] of ANSI_KEYS) {
    const value = raw[themeKey]
    if (typeof value === "string" && value !== "") {
      result[xtermKey] = value
    }
  }
  return result
}
