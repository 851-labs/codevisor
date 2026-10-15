export type Check = (value: unknown) => boolean

export const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value)

export const isString = (value: unknown): value is string => typeof value === "string"

export const isNumber = (value: unknown): value is number => typeof value === "number"

export const isBoolean = (value: unknown): value is boolean => typeof value === "boolean"

export const optional =
  (check: Check): Check =>
  (value) =>
    value === undefined || check(value)

export const nullable =
  (check: Check): Check =>
  (value) =>
    value === null || check(value)

export const recordOf =
  (check: Check): Check =>
  (value) =>
    isRecord(value) && Object.values(value).every(check)

export const shape =
  <T>(fields: Readonly<Record<keyof T & string, Check>>) =>
  (value: unknown): value is T =>
    isRecord(value) && Object.entries<Check>(fields).every(([key, check]) => check(value[key]))

export function expectShape<T>(
  value: unknown,
  matches: (value: unknown) => value is T,
  description: string
): T {
  if (!matches(value)) throw new Error(`${description} has an unexpected shape`)
  return value
}
