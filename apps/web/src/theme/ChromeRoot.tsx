import { useLayoutEffect, useRef } from "react"

import { codevisorChromeMapping } from "./codevisorChromeMapping"
import { useChromeThemeProps } from "./useChromeThemeProps"

// camelCase CSSProperties key (backgroundColor) → CSS property (background-color).
function cssPropertyName(key: string): string {
  return key.startsWith("--") ? key : key.replace(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`)
}

// Applies the derived chrome style as inline style on <html> so the CSS
// variables cascade everywhere — including Base UI popups, which portal into
// document.body and would not inherit variables set on an app wrapper element.
// Inline custom properties on the root also override the static
// :root/.light/.dark token fallbacks in styles/app.css, which is exactly the
// precedence the token contract wants: fallback until a theme resolves, then
// the derived palette everywhere.
export function ChromeRoot() {
  const { style } = useChromeThemeProps(codevisorChromeMapping)
  const appliedProperties = useRef<Set<string>>(new Set())

  useLayoutEffect(() => {
    const root = document.documentElement
    const next = new Set<string>()
    for (const [key, value] of Object.entries(style)) {
      if (typeof value !== "string") continue
      const property = cssPropertyName(key)
      root.style.setProperty(property, value)
      next.add(property)
    }
    // Drop properties the previous theme set that the new one doesn't (e.g.
    // scrollbar colors on themes without an editor background).
    for (const property of appliedProperties.current) {
      if (!next.has(property)) root.style.removeProperty(property)
    }
    appliedProperties.current = next
  }, [style])

  // Restore the static fallbacks if the chrome host ever unmounts.
  useLayoutEffect(() => {
    const applied = appliedProperties.current
    return () => {
      const root = document.documentElement
      for (const property of applied) root.style.removeProperty(property)
      applied.clear()
    }
  }, [])

  return null
}
