import { createThemeController, type ThemePersistence } from "@pierre/theming"

import { herdmanThemeCatalog } from "./themeCatalog"

export { herdmanThemeCatalog } from "./themeCatalog"

// The single owner of the app's theming state. Color mode (light/dark/system),
// the light/dark theme-name picks, and their persistence all live here, so
// there is no parallel state ownership. The controller creates and owns the
// resolver; consumers that need an explicit resolver use the
// herdmanThemeResolver alias below rather than creating a second cache.
//
// It is a module singleton: created once per page-load, surviving client-side
// navigations. Adapted from pierre's diffshub app (components/themeController.ts).

// MODE_KEY is also read by the pre-paint no-flash bootstrap script in
// index.html (which can't import this module); keep them in sync.
const MODE_KEY = "herdman-color-mode"
const LIGHT_THEME_KEY = "herdman-light-theme"
const DARK_THEME_KEY = "herdman-dark-theme"

function readKey(key: string): string | null {
  try {
    return globalThis.localStorage?.getItem(key) ?? null
  } catch {
    return null
  }
}

function writeKey(key: string, value: string): void {
  try {
    globalThis.localStorage?.setItem(key, value)
  } catch {
    // Storage may be unavailable (private mode / denied) — non-fatal.
  }
}

// Maps the controller's selection onto the app's three storage keys: mode as a
// plain `light`/`dark`/`system` string (what the bootstrap script reads), and
// the theme names under the herdman-prefixed keys.
const herdmanPersistence: ThemePersistence = {
  load() {
    const mode = readKey(MODE_KEY)
    const light = readKey(LIGHT_THEME_KEY)
    const dark = readKey(DARK_THEME_KEY)
    if (mode == null && light == null && dark == null) return null
    const validMode = mode === "light" || mode === "dark" || mode === "system" ? mode : "system"
    return {
      mode: validMode,
      lightThemeName: light ?? herdmanThemeCatalog.defaultLightThemeName,
      darkThemeName: dark ?? herdmanThemeCatalog.defaultDarkThemeName
    }
  },
  save(selection) {
    writeKey(MODE_KEY, selection.mode)
    writeKey(LIGHT_THEME_KEY, selection.lightThemeName)
    writeKey(DARK_THEME_KEY, selection.darkThemeName)
  }
}

export const themeController = createThemeController({
  catalog: herdmanThemeCatalog,
  persistence: herdmanPersistence,
  defaultMode: "system"
})

export const herdmanThemeResolver = themeController.resolver
