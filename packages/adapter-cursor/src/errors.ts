export type CursorTerminalErrorKind =
  | "retriable"
  | "non_retriable"
  | "action_required"
  | "cancelled"
  | "usage_limit"

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

const USAGE_LIMIT_NOTICES = ["Upgrade your plan to continue", "Add a payment method to continue"]

export const couldBeCursorTerminalError = (text: string): boolean =>
  couldBeErrorSentinel(text.trimStart()) || couldBeUsageLimitNotice(text.trim())

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

const terminalErrorKind = (name: string | undefined): CursorTerminalErrorKind => {
  if (name === "RetriableError") return "retriable"
  if (name === "NonRetriableError") return "non_retriable"
  if (name === "ActionRequiredError") return "action_required"
  return "cancelled"
}

export const parseCursorTerminalError = (text: string): CursorTerminalError | undefined => {
  const match =
    /^\s*Error:\s*(RetriableError|NonRetriableError|ActionRequiredError|CancelledError):\s*(.*?)\s*$/s.exec(
      text
    )
  if (match === null) return usageLimitNotice(text)
  const name = match[1]
  const rawDetail = match[2] ?? ""
  const kind = terminalErrorKind(name)
  return {
    kind,
    message: cursorErrorMessage(kind, rawDetail),
    rawDetail,
    retryable: kind === "retriable"
  }
}

const couldBeErrorSentinel = (candidate: string): boolean =>
  ERROR_PREFIXES.some((prefix) => prefix.startsWith(candidate) || candidate.startsWith(prefix))

const couldBeUsageLimitNotice = (candidate: string): boolean =>
  USAGE_LIMIT_NOTICES.some((notice) => notice.startsWith(candidate))

const usageLimitNotice = (text: string): CursorTerminalError | undefined => {
  const notice = text.trim()
  if (!USAGE_LIMIT_NOTICES.includes(notice)) return undefined
  return { kind: "usage_limit", message: notice, rawDetail: notice, retryable: false }
}
