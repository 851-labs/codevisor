import { Schema } from "effect"

export const isoTimestamp = (): string => new Date().toISOString()

export const decode =
  <S extends Schema.ConstraintDecoder<unknown>>(schema: S) =>
  (input: unknown): S["Type"] =>
    Schema.decodeUnknownSync(schema)(input)

export const encode =
  <S extends Schema.ConstraintEncoder<unknown>>(schema: S) =>
  (input: S["Type"]): S["Encoded"] =>
    Schema.encodeSync(schema)(input)
