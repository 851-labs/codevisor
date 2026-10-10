import { HttpFailure } from "../server-http.js"

/// Lifecycle route failures surface as conflicts with the manager's reason.
export const conflictFrom = (cause: unknown): HttpFailure =>
  new HttpFailure(409, cause instanceof Error ? cause.message : String(cause))
