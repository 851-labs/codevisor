import type { TerminalTitleStatus } from "./types.js"

const ACTIVITY_GLYPHS = new Set("·✢✳✶✻✽◐◓◑◒")
const isBraille = (glyph: string): boolean => glyph >= "\u2800" && glyph <= "\u28ff"

const WORKING = [/^[\u2800-\u28ff\u25d0-\u25d3] /u, /(?:^| )[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏](?: |$)/u]
const IDLE = /^✳ /u

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
