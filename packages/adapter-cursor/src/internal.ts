import { isPlainRecord } from "@codevisor/api"

export type JsonRecord = Record<string, unknown>

export const record = (value: unknown): JsonRecord | undefined =>
  isPlainRecord(value) ? value : undefined
