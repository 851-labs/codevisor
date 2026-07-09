import type { ColorMode, ColorScheme } from "@pierre/theming"
import { useThemeController } from "@pierre/theming/react"
import { createContext, type ReactNode, useCallback, useContext, useEffect, useMemo } from "react"

import { themeController } from "./themeController"

interface ThemeProviderProps {
  attribute?: "class" | `data-${string}` | Array<"class" | `data-${string}`>
  children: ReactNode
  enableColorScheme?: boolean
  value?: Partial<Record<ColorScheme, string>>
}

interface ThemeContextValue {
  colorMode: ColorMode
  colorModes: ColorMode[]
  resolvedColorScheme: ColorScheme
  setColorMode: (mode: ColorMode) => void
}

const COLOR_MODES: ColorMode[] = ["light", "dark", "system"]
const COLOR_SCHEMES: ColorScheme[] = ["light", "dark"]

const ThemeContext = createContext<ThemeContextValue | undefined>(undefined)

// Applies the already-resolved color scheme to <html>: the class/data-attribute
// contract and the native color-scheme. The resolved 'light'/'dark' comes
// straight from the theme controller, so this never re-derives it from a raw
// mode + system preference.
function applyColorScheme({
  attribute,
  enableColorScheme,
  resolvedColorScheme,
  value
}: {
  attribute: ThemeProviderProps["attribute"]
  enableColorScheme: boolean
  resolvedColorScheme: ColorScheme
  value: Partial<Record<ColorScheme, string>> | undefined
}) {
  const root = document.documentElement
  const resolvedValue = value?.[resolvedColorScheme] ?? resolvedColorScheme
  const attributes = Array.isArray(attribute) ? attribute : [attribute]
  const classValues = COLOR_SCHEMES.map((scheme) => value?.[scheme] ?? scheme)

  for (const currentAttribute of attributes) {
    if (currentAttribute === "class") {
      root.classList.remove(...classValues)
      root.classList.add(resolvedValue)
      continue
    }
    if (currentAttribute != null) {
      root.setAttribute(currentAttribute, resolvedValue)
    }
  }

  if (enableColorScheme) {
    root.style.colorScheme = resolvedColorScheme
  }
}

// Thin React binding over the @pierre/theming controller (the single owner of
// theming state). useThemeController subscribes to the controller for color
// mode + resolvedColorScheme; this component applies the resolved scheme to
// the DOM and exposes the useTheme() API. Selection and persistence live in
// the controller — this holds no theming state of its own.
//
// Adapted from pierre's diffshub ThemeProvider, minus the SSR machinery: this
// SPA renders client-only, so controller state is already correct on the first
// render and no mounted gate is needed. The pre-paint script in index.html
// painted the class before React loaded.
export function ThemeProvider({
  attribute = "class",
  children,
  enableColorScheme = true,
  value
}: ThemeProviderProps) {
  const state = useThemeController(themeController)

  useEffect(() => {
    applyColorScheme({
      attribute,
      enableColorScheme,
      resolvedColorScheme: state.resolvedColorScheme,
      value
    })
  }, [attribute, enableColorScheme, state.resolvedColorScheme, value])

  const setColorMode = useCallback((next: ColorMode) => {
    themeController.setColorMode(next)
  }, [])

  const contextValue = useMemo<ThemeContextValue>(
    () => ({
      colorMode: state.mode,
      colorModes: COLOR_MODES,
      resolvedColorScheme: state.resolvedColorScheme,
      setColorMode
    }),
    [state.mode, state.resolvedColorScheme, setColorMode]
  )

  return <ThemeContext.Provider value={contextValue}>{children}</ThemeContext.Provider>
}

export function useTheme(): ThemeContextValue {
  return (
    useContext(ThemeContext) ?? {
      colorMode: "system",
      colorModes: [],
      resolvedColorScheme: "light",
      setColorMode: () => {}
    }
  )
}
