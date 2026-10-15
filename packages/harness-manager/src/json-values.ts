export const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value)

export const recordOrEmpty = (value: unknown): Record<string, unknown> =>
  isRecord(value) ? value : {}

export const errnoCode = (cause: unknown): unknown =>
  typeof cause === "object" && cause !== null && "code" in cause ? cause.code : undefined

export const optionalString = (value: unknown): string | undefined =>
  typeof value === "string" ? value : undefined

export const optionalBoolean = (value: unknown): boolean | undefined =>
  typeof value === "boolean" ? value : undefined

export const optionalNumber = (value: unknown): number | undefined =>
  typeof value === "number" ? value : undefined

export const recordArray = (value: unknown): ReadonlyArray<Record<string, unknown>> =>
  Array.isArray(value) ? value.filter(isRecord) : []

export const parseJsonRecord = (raw: string): Record<string, unknown> => {
  const parsed: unknown = JSON.parse(raw)
  if (!isRecord(parsed)) throw new Error("Expected a JSON object")
  return parsed
}
