import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { isPlainRecord } from "@codevisor/api"

import { type JsonRecord } from "./internal.js"

export const recordOf = (value: unknown): JsonRecord => {
  if (!isPlainRecord(value)) throw new Error(`Expected an object, got ${String(value)}`)
  return value
}

export const payloadOf = (event: RuntimeEvent | undefined): JsonRecord | undefined =>
  event === undefined ? undefined : recordOf(event.payload)
