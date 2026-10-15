export type UnknownRecord = Readonly<Record<string, unknown>>

export const isRecord = (value: unknown): value is UnknownRecord =>
  typeof value === "object" && value !== null

export const isPlainRecord = (value: unknown): value is UnknownRecord =>
  isRecord(value) && !Array.isArray(value)

export const recordOrEmpty = (value: unknown): UnknownRecord => (isRecord(value) ? value : {})

export const recordOrUndefined = (value: unknown): UnknownRecord | undefined =>
  isRecord(value) ? value : undefined

export const recordsIn = (value: unknown): UnknownRecord[] =>
  Array.isArray(value) ? value.map(recordOrEmpty) : []

export const isStringArray = (value: unknown): value is string[] =>
  Array.isArray(value) && value.every((item) => typeof item === "string")

const unexpected = (label: string, expected: string): Error =>
  new Error(`${label} returned a non-${expected} value`)

export const expectString = (value: unknown, label: string): string => {
  if (typeof value !== "string") throw unexpected(label, "string")
  return value
}

export const expectBoolean = (value: unknown, label: string): boolean => {
  if (typeof value !== "boolean") throw unexpected(label, "boolean")
  return value
}

export const expectNumber = (value: unknown, label: string): number => {
  if (typeof value !== "number") throw unexpected(label, "number")
  return value
}

export const expectRecord = (value: unknown, label: string): UnknownRecord => {
  if (!isPlainRecord(value)) throw unexpected(label, "object")
  return value
}

export const expectArray = (value: unknown, label: string): ReadonlyArray<unknown> => {
  if (!Array.isArray(value)) throw unexpected(label, "array")
  return value
}

export const optionalString = (value: unknown): string | undefined =>
  typeof value === "string" ? value : undefined
