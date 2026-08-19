/// Typed failure surface for plugin operations, mapped onto HTTP statuses in
/// the server's writeFailure (invalid → 400, notFound → 404, unavailable →
/// 503, conflict → 409), mirroring SkillsError. `unavailable` covers the
/// supervisor refusing to (re)start a plugin: crash-backoff windows and a
/// tripped circuit breaker.
export type PluginsErrorCode = "invalid" | "notFound" | "conflict" | "unavailable"

export class PluginsError extends Error {
  constructor(
    readonly code: PluginsErrorCode,
    message: string
  ) {
    super(message)
  }
}
