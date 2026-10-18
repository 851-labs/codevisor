import type { TerminalTitleStatus } from "./types.js"

const ACTIVITY_GLYPHS = new Set("·✢✳✶✻✽◐◓◑◒")
const isBraille = (glyph: string): boolean => glyph >= "\u2800" && glyph <= "\u28ff"

const WORKING = [/^[\u2800-\u28ff\u25d0-\u25d3] /u, /(?:^| )[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏](?: |$)/u]
const IDLE = /^✳ /u

export const terminalTitleStatus = (raw: string): TerminalTitleStatus => {
  const trimmed = raw.trim()
  const [first = ""] = trimmed
  const rest = trimmed.slice(first.length)
  let stripped = trimmed
  if ((isBraille(first) || ACTIVITY_GLYPHS.has(first)) && (rest === "" || /^\s/u.test(rest))) {
    stripped = rest.trim()
  }
  const title = stripped === "" ? undefined : stripped
  let activity: TerminalTitleStatus["activity"] = undefined
  if (WORKING.some((pattern) => pattern.test(raw))) {
    activity = "working"
  } else if (IDLE.test(raw)) {
    activity = "idle"
  }
  return { title, activity }
}
