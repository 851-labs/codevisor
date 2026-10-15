export const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null

export const isNonArrayRecord = (value: unknown): value is Record<string, unknown> =>
  isRecord(value) && !Array.isArray(value)

export const isMissingFileError = (cause: unknown): boolean =>
  isRecord(cause) && cause.code === "ENOENT"
