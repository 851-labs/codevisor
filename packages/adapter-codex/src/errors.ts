import { isRecord } from "./internal.js"

const codexErrorSignal = (
  info: unknown
): { kind: string | undefined; statusCode: number | undefined } => {
  if (typeof info === "string") return { kind: info, statusCode: undefined }
  if (!isRecord(info)) return { kind: undefined, statusCode: undefined }

  // Unit variants serialize as strings, while variants carrying an HTTP
  // status serialize as `{ responseStreamConnectionFailed: { httpStatusCode } }`.
  // Keep accepting the older flattened shape too.
  const variant = Object.entries(info).find(([key]) => key !== "httpStatusCode")
  const variantDetails = variant === undefined || !isRecord(variant[1]) ? undefined : variant[1]
  const statusCode =
    typeof info.httpStatusCode === "number"
      ? info.httpStatusCode
      : typeof variantDetails?.httpStatusCode === "number"
        ? variantDetails.httpStatusCode
        : undefined
  return { kind: variant?.[0], statusCode }
}

export const codexErrorDetails = (
  payload: Record<string, unknown>
): { message: string; retryable: boolean } => {
  const error = isRecord(payload.error) ? payload.error : payload
  const message =
    typeof error.message === "string"
      ? error.message
      : typeof payload.message === "string"
        ? payload.message
        : "Codex error"
  const info = error.codexErrorInfo
  const signal = codexErrorSignal(info)
  const serializedInfo = (() => {
    try {
      return JSON.stringify(info)
    } catch {
      return ""
    }
  })()
  // Codex distinguishes exhausted subscription/workspace usage from transient
  // request throttling. UsageLimitExceeded is terminal and already carries
  // richer user-facing copy (including reset time or credit guidance), so it
  // must never be presented as a reconnecting server.
  const usageLimitExceeded = signal.kind === "usageLimitExceeded"
  const retryable =
    !usageLimitExceeded &&
    (signal.kind === "serverOverloaded" ||
      signal.kind === "rateLimitExceeded" ||
      signal.statusCode === 429 ||
      signal.statusCode === 503 ||
      /serverOverloaded|rateLimitExceeded|"httpStatusCode"\s*:\s*(?:429|503)/i.test(
        serializedInfo
      ) ||
      /\b(overload(?:ed)?|server (?:is )?busy|rate.?limit|429|503)\b/i.test(message))
  return { message, retryable }
}

export const codexRetryStatus = (payload: Record<string, unknown>) => {
  const error = isRecord(payload.error) ? payload.error : payload
  const rawMessage =
    typeof error.message === "string"
      ? error.message
      : typeof payload.message === "string"
        ? payload.message
        : ""
  const signal = codexErrorSignal(error.codexErrorInfo)
  const serializedInfo = (() => {
    try {
      return JSON.stringify(error.codexErrorInfo)
    } catch {
      return ""
    }
  })()
  const progress = /(?:reconnecting|retrying)[^\d]*(\d+)\s*\/\s*(\d+)/i.exec(rawMessage)
  const message =
    signal.kind === "usageLimitExceeded"
      ? "Codex usage limit reached"
      : signal.kind === "serverOverloaded" ||
          signal.statusCode === 503 ||
          /serverOverloaded/i.test(serializedInfo) ||
          /\b(overload(?:ed)?|server (?:is )?busy|503)\b/i.test(rawMessage)
        ? "Codex is overloaded, retrying"
        : signal.kind === "rateLimitExceeded" ||
            signal.statusCode === 429 ||
            /rateLimitExceeded/i.test(serializedInfo) ||
            /\b(rate.?limit|429)\b/i.test(rawMessage)
          ? "Codex is temporarily rate limited, retrying"
          : "Codex connection was interrupted, retrying"
  return {
    ...(progress?.[1] === undefined ? {} : { attempt: Number(progress[1]) }),
    message,
    ...(progress?.[2] === undefined ? {} : { of: Number(progress[2]) })
  }
}
