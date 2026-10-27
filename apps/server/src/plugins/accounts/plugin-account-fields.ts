import { randomBytes } from "node:crypto"

import type { ConfigField, ConfigFieldValue } from "@codevisor/api"

import { HttpFailure } from "../../server-context.js"

export interface SplitFieldValues {
  readonly values: Readonly<Record<string, ConfigFieldValue>>
  readonly secrets: Readonly<Record<string, string>>
}

export const splitFieldValues = (
  fields: ReadonlyArray<ConfigField>,
  submitted: Readonly<Record<string, unknown>>,
  existingSecrets: Readonly<Record<string, string>> = {}
): SplitFieldValues => {
  const values: Record<string, ConfigFieldValue> = {}
  const secrets: Record<string, string> = {}
  for (const field of fields) {
    if (!applies(field, submitted)) continue
    const value = fieldValue(field, submitted[field.key], existingSecrets[field.key])
    if (value === undefined) continue
    if (field.type === "secret") secrets[field.key] = String(value)
    else values[field.key] = value
  }
  return { values, secrets }
}

const applies = (field: ConfigField, submitted: Readonly<Record<string, unknown>>): boolean => {
  if (field.when === undefined) return true
  const matches = submitted[field.when.key] === field.when.value
  return field.when.op === "eq" ? matches : !matches
}

const fieldValue = (
  field: ConfigField,
  raw: unknown,
  existingSecret: string | undefined
): ConfigFieldValue | undefined => {
  const value = providedValue(field, raw, existingSecret)
  if (value === undefined) return requiredMissing(field)
  return validated(field, value)
}

const providedValue = (
  field: ConfigField,
  raw: unknown,
  existingSecret: string | undefined
): unknown => {
  if (!isBlank(raw)) return typeof raw === "string" ? raw.trim() : raw
  if (field.type === "secret" && existingSecret !== undefined) return existingSecret
  if (field.generated === true) return randomBytes(24).toString("base64url")
  return field.default
}

const requiredMissing = (field: ConfigField): undefined => {
  if (field.required) throw new HttpFailure(400, `${field.label} is required`)
  return undefined
}

const validated = (field: ConfigField, value: unknown): ConfigFieldValue => {
  switch (field.type) {
    case "number":
      return numberValue(field, value)
    case "boolean":
      return booleanValue(field, value)
    case "url":
      return urlValue(field, value)
    case "choice":
      return choiceValue(field, value)
    default:
      return stringValue(field, value)
  }
}

const numberValue = (field: ConfigField, value: unknown): number => {
  const number = typeof value === "number" ? value : Number(value)
  if (!Number.isFinite(number)) throw invalid(field, "must be a number")
  if (field.min !== undefined && number < field.min)
    throw invalid(field, `must be at least ${field.min}`)
  if (field.max !== undefined && number > field.max)
    throw invalid(field, `must be at most ${field.max}`)
  return number
}

const booleanValue = (field: ConfigField, value: unknown): boolean => {
  if (typeof value === "boolean") return value
  if (value === "true" || value === "false") return value === "true"
  throw invalid(field, "must be true or false")
}

const urlValue = (field: ConfigField, value: unknown): string => {
  const text = stringValue(field, value)
  if (!isHttpUrl(text)) throw invalid(field, "must be an http or https URL")
  return text.replace(/\/+$/, "")
}

const choiceValue = (field: ConfigField, value: unknown): string => {
  const text = stringValue(field, value)
  if (field.choices?.some((choice) => choice.value === text) === true) return text
  throw invalid(field, "isn't one of the choices")
}

const stringValue = (field: ConfigField, value: unknown): string => {
  if (typeof value !== "string") throw invalid(field, "must be text")
  return value
}

const isHttpUrl = (text: string): boolean => {
  try {
    const url = new URL(text)
    return url.protocol === "https:" || url.protocol === "http:"
  } catch {
    return false
  }
}

const isBlank = (value: unknown): boolean =>
  value === undefined || value === null || (typeof value === "string" && value.trim() === "")

const invalid = (field: ConfigField, problem: string): HttpFailure =>
  new HttpFailure(400, `${field.label} ${problem}`)
