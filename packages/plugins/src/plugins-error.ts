export type PluginsErrorCode = "invalid" | "notFound" | "conflict" | "unavailable"

export class PluginsError extends Error {
  constructor(
    readonly code: PluginsErrorCode,
    message: string
  ) {
    super(message)
  }
}
