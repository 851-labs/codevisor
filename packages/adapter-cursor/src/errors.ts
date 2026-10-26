export type CursorTerminalErrorKind =
  | "retriable"
  | "non_retriable"
  | "action_required"
  | "cancelled"
  | "usage_limit"
  | "auth_required"

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

const UNAUTHENTICATED_PREFIX = "Error: [unauthenticated]"

const ERROR_PREFIXES = [...ERROR_NAMES.map((name) => `Error: ${name}:`), UNAUTHENTICATED_PREFIX]

const ACTION_NOTICES: ReadonlyMap<string, CursorTerminalErrorKind> = new Map([
  ["Upgrade your plan to continue", "usage_limit"],
  ["Add a payment method to continue", "usage_limit"],
  ["Please sign in to continue", "auth_required"],
  ["Check your settings to continue", "action_required"]
])

export const couldBeCursorTerminalError = (text: string): boolean =>
  couldBeErrorSentinel(text.trimStart()) || couldBeActionNotice(text.trim())

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
  if (match === null) return unauthenticatedError(text) ?? actionNotice(text)
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

const couldBeActionNotice = (candidate: string): boolean =>
  [...ACTION_NOTICES.keys()].some((notice) => notice.startsWith(candidate))

const unauthenticatedError = (text: string): CursorTerminalError | undefined => {
  const detail = text.trim()
  if (!detail.startsWith(UNAUTHENTICATED_PREFIX)) return undefined
  const rawDetail = detail.slice(UNAUTHENTICATED_PREFIX.length).trim()
  return { kind: "auth_required", message: rawDetail, rawDetail, retryable: false }
}

const actionNotice = (text: string): CursorTerminalError | undefined => {
  const notice = text.trim()
  const kind = ACTION_NOTICES.get(notice)
  if (kind === undefined) return undefined
  return { kind, message: notice, rawDetail: notice, retryable: false }
}
