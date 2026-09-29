import type { TerminalTitleStatus } from "./types.js"

// Claude Code prefixes its title with one of these (plus braille spinner
// frames); herdr strips the same set (src/terminal/title.rs).
const ACTIVITY_GLYPHS = new Set("·✢✳✶✻✽◐◓◑◒")
const isBraille = (glyph: string): boolean => glyph >= "\u2800" && glyph <= "\u28ff"

// Claude Code: braille spinner (up to 2.1.227) or half circles (2.1.228+)
// while busy, `✳` at its prompt. Codex: a braille spinner frame as its own
// word anywhere in the title. Patterns follow herdr's claude/codex manifests.
const WORKING = [/^[\u2800-\u28ff\u25d0-\u25d3] /u, /(?:^| )[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏](?: |$)/u]
const IDLE = /^✳ /u

/// Reads a raw OSC 0/2 title. Only one leading glyph is dropped, and only
/// when a word boundary follows it, so titles such as "★task" or "✨ deploy"
/// keep their decoration. An empty result is no title.
export const terminalTitleStatus = (raw: string): TerminalTitleStatus => {
  const trimmed = raw.trim()
  const [first = ""] = trimmed
  const rest = trimmed.slice(first.length)
  const stripped =
    (isBraille(first) || ACTIVITY_GLYPHS.has(first)) && (rest === "" || /^\s/u.test(rest))
      ? rest.trim()
      : trimmed
  return {
    title: stripped === "" ? undefined : stripped,
    activity: WORKING.some((pattern) => pattern.test(raw))
      ? "working"
      : IDLE.test(raw)
        ? "idle"
        : undefined
  }
}
