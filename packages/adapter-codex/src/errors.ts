import type { TurnStopKind } from "@codevisor/api"

import { isRecord } from "./internal.js"

export const codexSignedOutDetail = "Codex isn't signed in. Sign in to continue."

const codexErrorSignal = (
  info: unknown
): { kind: string | undefined; statusCode: number | undefined } => {
  if (typeof info === "string") return { kind: info, statusCode: undefined }
  if (!isRecord(info)) return { kind: undefined, statusCode: undefined }

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

const codexErrorMessage = (
  error: Record<string, unknown>,
  payload: Record<string, unknown>,
  fallback: string
): string => {
  if (typeof error.message === "string") return error.message
  if (typeof payload.message === "string") return payload.message
  return fallback
}

export const codexErrorDetails = (
  payload: Record<string, unknown>
): { message: string; retryable: boolean; stopKind?: TurnStopKind } => {
  const error = isRecord(payload.error) ? payload.error : payload
  const message = codexErrorMessage(error, payload, "Codex error")
  const info = error.codexErrorInfo
  const signal = codexErrorSignal(info)
  if (signal.kind === "unauthorized" || signal.statusCode === 401) {
    return { message: codexSignedOutDetail, retryable: false, stopKind: "authRequired" }
  }
  const serializedInfo = (() => {
    try {
      return JSON.stringify(info)
    } catch {
      return ""
    }
  })()
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
  return {
    message,
    retryable,
    ...(usageLimitExceeded ? { stopKind: "usageLimit" as const } : {})
  }
}

const codexRetryMessage = (
  signal: ReturnType<typeof codexErrorSignal>,
  serializedInfo: string,
  rawMessage: string
): string => {
  if (signal.kind === "usageLimitExceeded") return "Codex usage limit reached"
  if (
    signal.kind === "serverOverloaded" ||
    signal.statusCode === 503 ||
    /serverOverloaded/i.test(serializedInfo) ||
    /\b(overload(?:ed)?|server (?:is )?busy|503)\b/i.test(rawMessage)
  ) {
    return "Codex is overloaded, retrying"
  }
  if (
    signal.kind === "rateLimitExceeded" ||
    signal.statusCode === 429 ||
    /rateLimitExceeded/i.test(serializedInfo) ||
    /\b(rate.?limit|429)\b/i.test(rawMessage)
  ) {
    return "Codex is temporarily rate limited, retrying"
  }
  return "Codex connection was interrupted, retrying"
}

export const codexRetryStatus = (payload: Record<string, unknown>) => {
  const error = isRecord(payload.error) ? payload.error : payload
  const rawMessage = codexErrorMessage(error, payload, "")
  const signal = codexErrorSignal(error.codexErrorInfo)
  const serializedInfo = (() => {
    try {
      return JSON.stringify(error.codexErrorInfo)
    } catch {
      return ""
    }
  })()
  const progress = /(?:reconnecting|retrying)[^\d]*(\d+)\s*\/\s*(\d+)/i.exec(rawMessage)
  const message = codexRetryMessage(signal, serializedInfo, rawMessage)
  return {
    ...(progress?.[1] === undefined ? {} : { attempt: Number(progress[1]) }),
    message,
    ...(progress?.[2] === undefined ? {} : { of: Number(progress[2]) })
  }
}
