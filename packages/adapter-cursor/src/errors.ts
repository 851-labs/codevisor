export type CursorTerminalErrorKind =
  | "retriable"
  | "non_retriable"
  | "action_required"
  | "cancelled"

export interface CursorTerminalError {
  readonly kind: CursorTerminalErrorKind
  readonly message: string
  readonly rawDetail: string
  readonly retryable: boolean
}

const ERROR_NAMES = [
  "RetriableError",
  "NonRetriableError",
  "ActionRequiredError",
  "CancelledError"
] as const

const ERROR_PREFIXES = ERROR_NAMES.map((name) => `Error: ${name}:`)

/// Cursor's ACP bridge serializes its typed CLI errors as assistant text. Hold
/// only a possible leading sentinel; ordinary response text streams at once.
export const couldBeCursorTerminalError = (text: string): boolean => {
  const candidate = text.trimStart()
  return ERROR_PREFIXES.some(
    (prefix) => prefix.startsWith(candidate) || candidate.startsWith(prefix)
  )
}

const cursorErrorMessage = (kind: CursorTerminalErrorKind, detail: string): string => {
  const coded = /^\[([^\]]+)\]\s*(.*)$/s.exec(detail)
  const code = coded?.[1]?.toLowerCase()
  const remainder = coded?.[2]?.trim()
  if (code === "unavailable" && (remainder === undefined || /^error$/i.test(remainder))) {
    return "Cursor is temporarily unavailable."
  }
  if (code === "deadline_exceeded") return "Cursor's response timed out."
  if (kind === "action_required") {
    return detail.length === 0 ? "Cursor requires action before it can continue." : detail
  }
  return detail.length === 0 ? "Cursor ended the response unexpectedly." : detail
}

export const parseCursorTerminalError = (text: string): CursorTerminalError | undefined => {
  const match =
    /^\s*Error:\s*(RetriableError|NonRetriableError|ActionRequiredError|CancelledError):\s*(.*?)\s*$/s.exec(
      text
    )
  if (match === null) return undefined
  const name = match[1]
  const rawDetail = match[2] ?? ""
  const kind: CursorTerminalErrorKind =
    name === "RetriableError"
      ? "retriable"
      : name === "NonRetriableError"
        ? "non_retriable"
        : name === "ActionRequiredError"
          ? "action_required"
          : "cancelled"
  return {
    kind,
    message: cursorErrorMessage(kind, rawDetail),
    rawDetail,
    retryable: kind === "retriable"
  }
}
