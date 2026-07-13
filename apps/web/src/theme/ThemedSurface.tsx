import type { CSSProperties, ElementType, ReactNode } from "react"

import type { ChromeMapping } from "./chromeThemeProps"
import { codevisorChromeMapping } from "./codevisorChromeMapping"
import type { ThemeInput } from "./ThemeSource"
import { useChromeThemeProps } from "./useChromeThemeProps"

interface ThemedSurfaceProps {
  as?: ElementType
  children?: ReactNode
  className?: string
  mapping?: ChromeMapping
  style?: CSSProperties
  theme?: ThemeInput
}

// A scoped themed chrome host (e.g. theme-picker swatch previews). Renders
// `as` (default div) with the chrome style applied from the active theme via
// the given mapping (default codevisorChromeMapping). App-wide theming instead
// goes through ChromeRoot, which hoists the same style onto <html> so portaled
// popups inherit it. Caller `style` (spread after) still wins on key
// collisions.
export function ThemedSurface({
  as,
  children,
  className,
  mapping = codevisorChromeMapping,
  style,
  theme
}: ThemedSurfaceProps) {
  const Component = as ?? "div"
  const themeProps = useChromeThemeProps(mapping, theme)
  return (
    <Component className={className} style={{ ...themeProps.style, ...style }}>
      {children}
    </Component>
  )
}
