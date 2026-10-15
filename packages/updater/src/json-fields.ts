const isRecord = (value: unknown): value is Readonly<Record<string, unknown>> =>
  typeof value === "object" && value !== null

export const jsonField = (value: unknown, key: string): unknown =>
  isRecord(value) ? value[key] : undefined

export const jsonString = (value: unknown, key: string): string | undefined => {
  const field = jsonField(value, key)
  return typeof field === "string" ? field : undefined
}
