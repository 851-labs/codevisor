import { createThemeCatalog } from "@pierre/theming"
import { themes } from "@pierre/theming/themes"

// The full bundled catalog (pierre + shiki collections) the theme picker
// enumerates. Adapted from pierre's diffshub app (components/themeCatalog.ts).
export const herdmanThemeCatalog = createThemeCatalog({
  themes,
  defaultLightThemeName: "pierre-light-soft",
  defaultDarkThemeName: "pierre-dark-soft"
})
