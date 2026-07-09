// Pure mapping from the resolved active theme to a chrome CSS style. Runs
// deriveChromeTokens on the active theme and hands the derived tokens to a
// caller-supplied mapping (herdman uses herdmanChromeMapping). Returns a
// spreadable { style } that is an empty object until a theme resolves.
import type { CSSProperties } from "react"

import { deriveChromeTokens } from "./deriveChromeTokens"
import type { ChromeMapping } from "./herdmanChromeMapping"
import type { ActiveThemeSnapshot } from "./ThemeSource"

export type { ChromeMapping }

export function chromeThemeProps(
  active: ActiveThemeSnapshot,
  mapping: ChromeMapping
): { style: CSSProperties } {
  const theme = active.theme
  if (theme == null) return { style: {} }
  return { style: mapping(deriveChromeTokens(theme), theme) ?? {} }
}
