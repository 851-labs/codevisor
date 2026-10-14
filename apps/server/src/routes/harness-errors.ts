import { HttpFailure } from "../server-http.js"

export const conflictFrom = (cause: unknown): HttpFailure =>
  new HttpFailure(409, cause instanceof Error ? cause.message : String(cause))
