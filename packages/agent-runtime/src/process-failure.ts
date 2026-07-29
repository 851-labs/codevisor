/// Turns a crashed CLI's stderr into one short, human-readable sentence.
///
/// Harness CLIs are bundled/minified Node programs. When one dies during
/// startup it prints the offending source line, the error, and a deep
/// `__webpack_require__` stack — easily megabytes. We only retain the tail
/// (see `captureStderr`), but even that tail is mostly noise, and it used to
/// flow verbatim into `HarnessAccount.detail`, which onboarding renders as the
/// grey subtitle under the harness name. A user onboarding with a broken
/// `cursor-agent` saw a screenful of minified JavaScript instead of "Cursor
/// CLI failed to start".
///
/// The raw text stays available for logs; only the user-facing string is
/// condensed here.

/// Upper bound for a detail string surfaced in the UI. Long enough for a real
/// message ("Failed to load native binding for darwin/arm64 (expected:
/// ./merkle-tree-napi.darwin-arm64.node)" is 101 chars), short enough that a
/// row stays two lines.
export const maxFailureDetailLength = 240

/// A `  at fn (/path/file.js:1:2)` stack frame.
const stackFramePattern = /^at\s/

/// Node's `Node.js v24.5.0` footer — true but useless as a failure summary.
const nodeFooterPattern = /^Node\.js\s+v\d/

/// `Error: ...`, `TypeError: ...`, `Uncaught Error: ...` — the line we want.
const errorLinePattern = /^(?:Uncaught\s+)?(?:[A-Za-z_$][\w$]*)?Error:\s*(?<message>\S.*)$/

/// Minified bundle output: one enormous line with almost no spaces. Real
/// diagnostics wrap or stay short, so a long line that is <12% whitespace is
/// source, not a message.
const isMinifiedSource = (line: string): boolean =>
  line.length > 180 && line.replace(/[^ \t]/g, "").length / line.length < 0.12

const isNoise = (line: string): boolean =>
  line.length === 0 ||
  stackFramePattern.test(line) ||
  nodeFooterPattern.test(line) ||
  isMinifiedSource(line)

/// Collapses runs of whitespace and truncates on a word boundary when possible.
const clamp = (value: string, limit: number): string => {
  const collapsed = value.replace(/\s+/g, " ").trim()
  if (collapsed.length <= limit) return collapsed
  const cut = collapsed.slice(0, limit - 1)
  const lastSpace = cut.lastIndexOf(" ")
  return `${(lastSpace > limit * 0.6 ? cut.slice(0, lastSpace) : cut).trimEnd()}…`
}

/// Clamps an already-human message (used at persistence boundaries so a huge
/// string can never reach the database or the wire).
export const clampFailureDetail = (
  detail: string,
  limit = maxFailureDetailLength
): string | undefined => {
  const clamped = clamp(detail, limit)
  return clamped.length === 0 ? undefined : clamped
}

/// Extracts the most explanatory line from `stderr`, falling back to
/// `fallback` when the output is empty or entirely noise.
///
/// Prefers the first `Error:`-style line, because bundlers emit the real cause
/// before the stack; otherwise takes the first surviving line.
export const summarizeProcessFailure = (stderr: string, fallback: string): string => {
  const lines = stderr.split(/\r?\n/).map((line) => line.trim())
  const meaningful = lines.filter((line) => !isNoise(line))

  for (const line of meaningful) {
    const match = errorLinePattern.exec(line)
    if (match?.groups?.message !== undefined) {
      return clamp(match.groups.message, maxFailureDetailLength)
    }
  }

  const first = meaningful[0]
  return first === undefined ? fallback : clamp(first, maxFailureDetailLength)
}
