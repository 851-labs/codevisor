import { isPlainRecord, isRecord } from "@codevisor/api"

export type JsonRecord = Record<string, unknown>

export const record = (value: unknown): JsonRecord | undefined =>
  isRecord(value) ? value : undefined

export const objectRecord = (value: unknown): JsonRecord | undefined =>
  isPlainRecord(value) ? value : undefined
