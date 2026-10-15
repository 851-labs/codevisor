import { isRecord } from "@codevisor/api"

export const record = (value: unknown): Record<string, unknown> => (isRecord(value) ? value : {})

export const errorMessage = (cause: unknown): string =>
  cause instanceof Error ? cause.message : String(cause)
