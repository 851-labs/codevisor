import { createThemeResolver } from "@pierre/theming"
import { type CSSProperties, useMemo } from "react"

import { type ChromeMapping, chromeThemeProps } from "./chromeThemeProps"
import { fixedSource, type ThemeInput } from "./ThemeSource"
import { useThemeResolver, useThemeSource } from "./useThemeSource"

// Returns the spreadable chrome style props for the active theme, mapped to
// the app's CSS variables by the supplied mapping (herdman passes
// herdmanChromeMapping).
export function useChromeThemeProps(
  mapping: ChromeMapping,
  theme?: ThemeInput
): { style: CSSProperties } {
  const providerSource = useThemeSource()
  const contextResolver = useThemeResolver()
  const colorScheme = providerSource.activeTheme.colorScheme
  const localResolver = useMemo(() => createThemeResolver(), [])
  const resolver = contextResolver ?? localResolver
  const override = useMemo(() => {
    if (theme == null) return undefined
    return fixedSource(theme, { resolver, colorScheme })
  }, [theme, resolver, colorScheme])
  const { activeTheme } = useThemeSource(override)
  return useMemo(() => chromeThemeProps(activeTheme, mapping), [activeTheme, mapping])
}
