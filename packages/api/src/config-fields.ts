import { Schema } from "effect"

export const ConfigFieldValue = Schema.Union([Schema.String, Schema.Number, Schema.Boolean])
export type ConfigFieldValue = typeof ConfigFieldValue.Type

export const ConfigFieldValues = Schema.Record(Schema.String, ConfigFieldValue)
export type ConfigFieldValues = typeof ConfigFieldValues.Type

export const ConfigFieldType = Schema.Literals([
  "string",
  "secret",
  "url",
  "number",
  "boolean",
  "choice",
  "machine"
])
export type ConfigFieldType = typeof ConfigFieldType.Type

export const ConfigFieldCondition = Schema.Struct({
  key: Schema.String,
  op: Schema.Literals(["eq", "neq"]),
  value: ConfigFieldValue
})
export type ConfigFieldCondition = typeof ConfigFieldCondition.Type

export const ConfigField = Schema.Struct({
  key: Schema.String,
  label: Schema.String,
  type: ConfigFieldType,
  required: Schema.Boolean,
  default: Schema.optional(ConfigFieldValue),
  choices: Schema.optional(
    Schema.Array(Schema.Struct({ value: Schema.String, label: Schema.String }))
  ),
  placeholder: Schema.optional(Schema.String),
  help: Schema.optional(Schema.String),
  min: Schema.optional(Schema.Number),
  max: Schema.optional(Schema.Number),
  capability: Schema.optional(Schema.String),
  generated: Schema.optional(Schema.Boolean),
  when: Schema.optional(ConfigFieldCondition)
})
export type ConfigField = typeof ConfigField.Type
