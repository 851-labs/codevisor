export const isRecord = (value: unknown): value is Readonly<Record<string, unknown>> =>
  typeof value === "object" && value !== null && !Array.isArray(value)

export const field = (value: unknown, key: string): unknown =>
  isRecord(value) ? value[key] : undefined

export const stringField = (value: unknown, key: string): string | undefined => {
  const found = field(value, key)
  return typeof found === "string" ? found : undefined
}

export const asRecord = (value: unknown): Readonly<Record<string, unknown>> =>
  isRecord(value) ? value : {}

export const recordField = (value: unknown, key: string): Readonly<Record<string, unknown>> =>
  asRecord(field(value, key))

export const errorCode = (error: unknown): unknown => field(error, "code")
