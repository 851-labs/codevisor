import { Schema } from "effect"

export const StringArray = Schema.Array(Schema.String)

export const JsonObject = Schema.Record(Schema.String, Schema.Unknown)

export const parseJsonColumn = <S extends Schema.Constraint>(schema: S, raw: string): S["Type"] => {
  const parsed: unknown = JSON.parse(raw)
  Schema.asserts(schema, parsed)
  return parsed
}

export const parseJsonObject = (raw: string): Record<string, unknown> =>
  parseJsonColumn(JsonObject, raw)

export const payloadGeneration = (raw: string, fallback: number): number =>
  Number(parseJsonObject(raw).generation ?? fallback)
