import { isPlainRecord } from "@codevisor/api"
import { Schema } from "effect"

export type JsonRecord = Record<string, unknown>

export const record = (value: unknown): JsonRecord | undefined =>
  isPlainRecord(value) ? value : undefined

const decodeEnvelope = Schema.decodeUnknownSync(Schema.Struct({ data: Schema.Unknown }))
const decodeList = Schema.decodeUnknownSync(Schema.Array(Schema.Unknown))

export const responseData = <T>(schema: Schema.Codec<T, unknown>): ((value: unknown) => T) => {
  const decode = Schema.decodeUnknownSync(schema)
  return (value) => decode(decodeEnvelope(value).data)
}

export const responseList = <T>(
  schema: Schema.Codec<T, unknown>
): ((value: unknown) => ReadonlyArray<T>) => {
  const is = Schema.is(schema)
  return (value) => decodeList(decodeEnvelope(value).data).filter(is)
}
