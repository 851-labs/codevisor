export type SandboxFieldType =
  | "string"
  | "secret"
  | "url"
  | "number"
  | "boolean"
  | "choice"
  | "machine"

export type SandboxFieldValue = string | number | boolean

export type SandboxFieldValues = Readonly<Record<string, SandboxFieldValue>>

export interface SandboxFieldChoice {
  readonly value: string
  readonly label: string
}

export interface SandboxField {
  readonly key: string
  readonly label: string
  readonly type: SandboxFieldType
  readonly required: boolean
  readonly default?: SandboxFieldValue
  readonly choices?: ReadonlyArray<SandboxFieldChoice>
  readonly placeholder?: string
  readonly help?: string
  readonly min?: number
  readonly max?: number
  readonly steps?: ReadonlyArray<number>
  readonly fallbackMax?: number
  readonly unit?: string
  readonly capability?: string
}

export type SandboxFieldMaximums = Readonly<Record<string, number>>

export class SandboxFieldError extends Error {
  override readonly name = "SandboxFieldError"
}

type FieldDetails = Partial<Omit<SandboxField, "key" | "label" | "type">>

export const textField = (key: string, label: string, details: FieldDetails = {}): SandboxField =>
  field(key, label, "string", details)

export const secretField = (key: string, label: string, details: FieldDetails = {}): SandboxField =>
  field(key, label, "secret", details)

export const urlField = (key: string, label: string, details: FieldDetails = {}): SandboxField =>
  field(key, label, "url", details)

export const numberField = (key: string, label: string, details: FieldDetails = {}): SandboxField =>
  field(key, label, "number", details)

export const booleanField = (
  key: string,
  label: string,
  details: FieldDetails = {}
): SandboxField => field(key, label, "boolean", details)

export const choiceField = (
  key: string,
  label: string,
  choices: ReadonlyArray<SandboxFieldChoice>,
  details: FieldDetails = {}
): SandboxField => field(key, label, "choice", { ...details, choices })

export const machineField = (
  key: string,
  label: string,
  capability: string,
  details: FieldDetails = {}
): SandboxField => field(key, label, "machine", { ...details, capability })

export const readFields = (
  fields: ReadonlyArray<SandboxField>,
  raw: Readonly<Record<string, unknown>>
): SandboxFieldValues => {
  const values: Record<string, SandboxFieldValue> = {}
  for (const entry of fields) {
    const value = readField(entry, raw[entry.key])
    if (value !== undefined) values[entry.key] = value
  }
  return values
}

export const cappedFields = (
  fields: ReadonlyArray<SandboxField>,
  maximums: SandboxFieldMaximums
): ReadonlyArray<SandboxField> => fields.map((entry) => capped(entry, maximums[entry.key]))

export const fieldDefaults = (fields: ReadonlyArray<SandboxField>): SandboxFieldValues =>
  Object.fromEntries(
    fields.flatMap((entry) => (entry.default === undefined ? [] : [[entry.key, entry.default]]))
  )

export const withoutSecrets = (
  fields: ReadonlyArray<SandboxField>,
  values: SandboxFieldValues
): SandboxFieldValues =>
  Object.fromEntries(Object.entries(values).filter(([key]) => !isSecret(fields, key)))

export const secretsSet = (
  fields: ReadonlyArray<SandboxField>,
  values: SandboxFieldValues
): ReadonlyArray<string> =>
  fields.filter((entry) => entry.type === "secret" && hasValue(values[entry.key])).map(keyOf)

export const keepingSecrets = (
  fields: ReadonlyArray<SandboxField>,
  previous: SandboxFieldValues,
  incoming: Readonly<Record<string, unknown>>
): Readonly<Record<string, unknown>> => {
  const kept = fields.filter((entry) => entry.type === "secret" && !hasValue(incoming[entry.key]))
  return {
    ...incoming,
    ...Object.fromEntries(kept.map((entry) => [entry.key, previous[entry.key]]))
  }
}

export const stringValue = (values: SandboxFieldValues, key: string): string => {
  const value = values[key]
  return typeof value === "string" ? value : ""
}

export const numberValue = (values: SandboxFieldValues, key: string, fallback: number): number => {
  const value = values[key]
  return typeof value === "number" ? value : fallback
}

export const optionalString = (values: SandboxFieldValues, key: string): string | undefined => {
  const value = stringValue(values, key)
  return value === "" ? undefined : value
}

const field = (
  key: string,
  label: string,
  type: SandboxFieldType,
  details: FieldDetails
): SandboxField => ({ key, label, type, required: false, ...details })

const readField = (entry: SandboxField, raw: unknown): SandboxFieldValue | undefined => {
  const value = hasValue(raw) ? raw : entry.default
  if (value === undefined) return missing(entry)
  if (entry.type === "number") return numberIn(entry, value)
  if (entry.type === "boolean") return booleanIn(entry, value)
  return textIn(entry, value)
}

const missing = (entry: SandboxField): undefined => {
  if (entry.required) throw new SandboxFieldError(`${entry.label} is required`)
  return undefined
}

const numberIn = (entry: SandboxField, value: unknown): number => {
  const number = typeof value === "string" ? Number(value.trim()) : value
  if (typeof number !== "number" || !Number.isFinite(number)) {
    throw new SandboxFieldError(`${entry.label} must be a number`)
  }
  if (outOfRange(entry, number)) throw new SandboxFieldError(rangeMessage(entry))
  if (notAStep(entry, number)) throw new SandboxFieldError(`${entry.label} must be a whole number`)
  return number
}

const booleanIn = (entry: SandboxField, value: unknown): boolean => {
  if (typeof value !== "boolean") throw new SandboxFieldError(`${entry.label} must be on or off`)
  return value
}

const textIn = (entry: SandboxField, value: unknown): string => {
  if (typeof value !== "string") throw new SandboxFieldError(`${entry.label} must be text`)
  const text = value.trim()
  if (entry.type === "url") return urlIn(entry, text)
  if (entry.type === "choice") return choiceIn(entry, text)
  return text
}

const urlIn = (entry: SandboxField, text: string): string => {
  if (!URL.canParse(text) || !/^https?:/i.test(text)) {
    throw new SandboxFieldError(`${entry.label} must be an http or https URL`)
  }
  return text.replace(/\/+$/, "")
}

const choiceIn = (entry: SandboxField, text: string): string => {
  if (entry.choices?.some((choice) => choice.value === text) === true) return text
  throw new SandboxFieldError(`${entry.label} must be one of ${choiceLabels(entry)}`)
}

const outOfRange = (entry: SandboxField, number: number): boolean =>
  (entry.min !== undefined && number < entry.min) || (entry.max !== undefined && number > entry.max)

const notAStep = (entry: SandboxField, number: number): boolean =>
  entry.steps !== undefined && !Number.isInteger(number)

const capped = (entry: SandboxField, maximum: number | undefined): SandboxField => {
  if (maximum === undefined) return entry
  return { ...entry, max: Math.min(entry.max ?? maximum, maximum) }
}

const rangeMessage = (entry: SandboxField): string => {
  if (entry.min !== undefined && entry.max !== undefined) {
    return `${entry.label} must be between ${entry.min} and ${entry.max}`
  }
  if (entry.min !== undefined) return `${entry.label} must be at least ${entry.min}`
  return `${entry.label} must be at most ${String(entry.max)}`
}

const choiceLabels = (entry: SandboxField): string =>
  (entry.choices ?? []).map((choice) => choice.label).join(", ")

const hasValue = (value: unknown): boolean =>
  value !== undefined && value !== null && !(typeof value === "string" && value.trim() === "")

const isSecret = (fields: ReadonlyArray<SandboxField>, key: string): boolean =>
  fields.some((entry) => entry.key === key && entry.type === "secret")

const keyOf = (entry: SandboxField): string => entry.key
