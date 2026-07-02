// The herdman-specific mapping from neutral ChromeTokens to the app's CSS
// variables: the shadcn vocabulary (--background/--color-background, ...) the
// UI kit reads through Tailwind, plus the --herdman-* surfaces from the token
// contract in styles/app.css. Adapted from pierre's diffshub app
// (lib/theme/diffshubChromeMapping.ts).
import type { ThemeLike } from "@pierre/theming"
import { colorUtils, normalizeThemeColors } from "@pierre/theming/color"
import type { CSSProperties } from "react"

import type { ChromeTokens } from "./deriveChromeTokens"

// A ChromeMapping turns the neutral chrome tokens (or undefined when the theme
// has no legible foreground) plus the source theme into a host CSS style. The
// theme is passed so a mapping can read the sidebar/editor backgrounds for the
// surfaces the mixes blend into.
export type ChromeMapping = (
  chrome: ChromeTokens | undefined,
  theme: ThemeLike
) => CSSProperties | undefined

export const herdmanChromeMapping: ChromeMapping = (chrome, theme) => {
  // The chrome background is the resolved theme's sidebar background, read
  // straight from the shared normalizeThemeColors surface derivation (the same
  // key trees deriveChromeTokens reads).
  const resolved = normalizeThemeColors(theme).colors
  const sidebarBg = resolved?.["sideBar.background"]
  const editorBg = resolved?.["editor.background"]
  const bg = typeof sidebarBg === "string" && sidebarBg !== "" ? sidebarBg : undefined

  // No chrome means deriveChromeTokens found no legible foreground (degenerate
  // bg-only theme). Paint just the background when we have one, otherwise
  // contribute nothing.
  if (chrome == null) {
    return bg != null ? ({ backgroundColor: bg } as CSSProperties) : undefined
  }

  const fg = chrome.fg
  // The base the herdman-specific mixes blend the foreground into.
  const base = bg ?? "transparent"
  const surfaceIsDark = colorUtils.isDarkSurface(bg, fg)
  const style: CSSProperties & Record<string, string> = {}
  if (bg != null) style.backgroundColor = bg
  style.color = fg
  style["--color-foreground"] = fg
  style["--foreground"] = fg
  style["--color-muted-foreground"] = chrome.mutedFg
  style["--muted-foreground"] = chrome.mutedFg
  style["--color-border"] = chrome.border
  style["--border"] = chrome.border
  style["--color-border-opaque"] = chrome.borderOpaque
  style["--border-opaque"] = chrome.borderOpaque
  style["--color-popover"] = chrome.surface
  style["--popover"] = chrome.surface
  style["--color-popover-foreground"] = fg
  style["--popover-foreground"] = fg
  style["--color-card"] = chrome.surface
  style["--card"] = chrome.surface
  style["--color-card-foreground"] = fg
  style["--card-foreground"] = fg
  style["--color-background"] = chrome.background
  style["--background"] = chrome.background
  style["--color-accent"] = chrome.surfaceHover
  style["--accent"] = chrome.surfaceHover
  style["--color-accent-foreground"] = fg
  style["--accent-foreground"] = fg
  // `secondary` is the segmented-control track. It must sit visibly behind the
  // buttons so toggle options read as one connected control, so it reuses the
  // slightly stronger hover mix.
  style["--color-secondary"] = chrome.surfaceHover
  style["--secondary"] = chrome.surfaceHover
  style["--color-secondary-foreground"] = fg
  style["--secondary-foreground"] = fg
  style["--color-input"] = chrome.surfaceHover
  style["--input"] = chrome.surfaceHover
  style["--color-muted"] = chrome.surfaceHover
  style["--muted"] = chrome.surfaceHover
  style["--color-primary"] = fg
  style["--primary"] = fg
  style["--color-primary-foreground"] = chrome.background
  style["--primary-foreground"] = chrome.background
  style["--color-ring"] = chrome.ring
  style["--ring"] = chrome.ring

  // Sidebar surface: the chrome host background itself.
  style["--herdman-sidebar-bg"] = chrome.background
  // Card surfaces: a touch softer than the popover (6/12/12 vs the neutral
  // 7/14/20 set), so they read as quiet inline rows rather than floating menus.
  style["--herdman-card-bg"] = `color-mix(in srgb, ${fg} 6%, ${base})`
  style["--herdman-card-hover-bg"] = `color-mix(in srgb, ${fg} 12%, ${base})`
  style["--herdman-card-border"] = `color-mix(in srgb, ${fg} 12%, ${base})`
  style["--herdman-popover-bg"] = chrome.surface
  style["--herdman-popover-fg"] = fg
  style["--herdman-popover-muted-fg"] = chrome.mutedFg
  style["--herdman-popover-hover-bg"] = chrome.surfaceHover
  style["--herdman-popover-selected-bg"] = chrome.surfaceSelected
  style["--herdman-popover-border"] = chrome.surfaceBorder
  style["--herdman-popover-shadow"] = chrome.surfaceShadow
  // The composer card sits on the editor surface when the theme distinguishes
  // it from the sidebar, mirroring the macOS controlBackgroundColor role.
  style["--herdman-composer-bg"] = editorBg ?? chrome.surface
  style["--herdman-composer-border"] = chrome.surfaceBorder
  // User message bubble: the foreground at a whisper over the base surface.
  style["--herdman-bubble-bg"] = `color-mix(in srgb, ${fg} 8%, ${base})`
  // Sidebar rows: hover is quieter than selection so the active session reads.
  style["--herdman-row-hover-bg"] = `color-mix(in srgb, ${fg} 8%, ${base})`
  style["--herdman-row-selected-bg"] = `color-mix(in srgb, ${fg} 14%, ${base})`
  style["--herdman-status-ok"] = chrome.additionFg
  style["--herdman-status-warn"] = surfaceIsDark ? "#f59e0b" : "#b45309"
  style["--herdman-status-error"] = chrome.deletionFg
  style["--herdman-terminal-bg"] = editorBg ?? chrome.background
  style["--herdman-diff-add-fg"] = chrome.additionFg
  style["--herdman-diff-del-fg"] = chrome.deletionFg
  if (chrome.scrollbarThumb != null) {
    style["--herdman-scrollbar-thumb-bg"] = chrome.scrollbarThumb
  }
  if (chrome.scrollbarTrack != null) {
    style["--herdman-scrollbar-track-bg"] = chrome.scrollbarTrack
  }
  return style as CSSProperties
}
